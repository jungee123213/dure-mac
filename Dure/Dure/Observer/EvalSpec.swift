// Dure/Dure/Observer/EvalSpec.swift
import Foundation

/// 평가 실행 명세. 스펙 v2 5절. **격리는 플래그 + 실행마다 init 줄 확인**(리뷰 P1-A, D-36 실측).
nonisolated enum EvalSpec {

    static let timeout: TimeInterval = 600
    static let tools = "Read,Grep,Glob"
    /// init 줄의 `tools` 는 이 집합의 부분집합이어야 한다. `StructuredOutput` 은 `--json-schema` 가 넣는 내장 툴이다(실측).
    static let allowedTools: Set<String> = ["Read", "Grep", "Glob", "StructuredOutput"]
    static let promptVersion = 3   // 3: 조율자 턴도 e: 로 인용할 수 있다(최종 리뷰 F3)

    /// 셸에 작은따옴표로 넘기므로 작은따옴표를 쓰지 않는다. 자유 서술 리포트는 받지 않는다 — 앱이 검증된 지적으로 렌더한다.
    static let schemaJSON = #"{"type":"object","required":["summary","findings"],"properties":{"summary":{"type":"string"},"notes":{"type":"string"},"findings":{"type":"array","items":{"type":"object","required":["group","kind","key","title","detail","evidence","severity","confidence"],"properties":{"group":{"enum":["dure","habit","tooling"]},"kind":{"enum":["missing_feature","friction","works_well","prompt","workflow","permission","claude_md","skill","mcp","cost"]},"key":{"type":"string"},"title":{"type":"string"},"detail":{"type":"string"},"suggestion":{"type":"string"},"apply_text":{"type":"string"},"evidence":{"type":"array","items":{"type":"object","required":["event","quote"],"properties":{"event":{"type":"string"},"quote":{"type":"string"}}}},"severity":{"enum":[1,2,3]},"confidence":{"enum":["high","low"]}}}}}}"#

    /// 평가 · 묻기 세션 공통. `--safe-mode` 는 CLAUDE.md · 스킬 · 플러그인 · 훅 · MCP 를 끄고, `--strict-mcp-config` 는 남은 MCP 설정을 무시한다.
    static func isolationArgs(sessionID: String) -> [String] {
        ["--safe-mode", "--strict-mcp-config", "--tools", tools, "--session-id", sessionID]
    }

    /// 모델을 넘기지 않는다(D-28). 프롬프트는 stdin — 인자로 주면 `--add-dir`(가변 인자)가 삼킨다(단계 3 실측).
    static func script(runDir: String, sessionID: String, addDirs: [String]) -> String {
        var s = "cd \(Spawn.quoted(runDir)) && claude -p --safe-mode --strict-mcp-config --tools \(tools)"
        s += " --session-id \(Spawn.quoted(sessionID)) --output-format stream-json --verbose"
        s += " --json-schema \(Spawn.quoted(schemaJSON))"
        for d in addDirs { s += " --add-dir \(Spawn.quoted(d))" }
        return s + " < prompt.md"
    }

    struct Output: Equatable, Sendable {
        var summary: String
        var notes: String?
        var findings: [EvalFinding]
        var costUSD: Double?
    }

    enum Failure: Error, Equatable, Sendable {
        case timedOut
        case process(status: Int32, stderrTail: String)
        case unsafeSession(String)
        case modelError(String)
        case badOutput(String)

        var message: String {
            switch self {
            case .timedOut: "10분 안에 끝나지 않았다"
            case let .process(status, tail): "실행 실패(종료 코드 \(status)): \(tail)"
            case let .unsafeSession(m): "격리 실패 — 평가 세션에 허용 밖의 툴 · MCP 가 있었다: \(m)"
            case let .modelError(m): "평가 중 오류: \(m)"
            case let .badOutput(m): "결과 형식이 맞지 않는다: \(m)"
            }
        }
    }

    private struct Structured: Decodable {
        var summary: String
        var notes: String?
        var findings: [EvalFinding]
    }

    static func interpret(_ r: CommandResult) -> Result<Output, Failure> {
        if r.timedOut { return .failure(.timedOut) }
        guard r.status == 0 else { return .failure(.process(status: r.status, stderrTail: CommandOutput.tail(r.stderr))) }
        let objects = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> [String: Any]? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
        }
        guard let initObj = objects.first(where: { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }) else {
            return .failure(.badOutput("init 줄이 없다"))
        }
        // 격리 확인은 닫힌 쪽으로 실패한다 — CLI 가 init 모양을 바꿔 필드가 사라지면 "비었다" 로 읽혀 통과하는 일이 없어야 한다.
        guard let tools = initObj["tools"] as? [String], let mcp = initObj["mcp_servers"] as? [Any] else {
            return .failure(.unsafeSession("init 줄 형식이 다르다"))
        }
        guard Set(tools).isSubset(of: allowedTools), mcp.isEmpty else {
            return .failure(.unsafeSession("툴 \(tools.sorted().joined(separator: ",")) · MCP \(mcp.count)개"))
        }
        guard let result = objects.last(where: { $0["type"] as? String == "result" }) else {
            return .failure(.badOutput("result 줄이 없다"))
        }
        if result["is_error"] as? Bool == true {
            return .failure(.modelError(result["result"] as? String ?? result["subtype"] as? String ?? "?"))
        }
        guard let so = result["structured_output"], let data = try? JSONSerialization.data(withJSONObject: so),
              let s = try? JSONDecoder().decode(Structured.self, from: data) else {
            return .failure(.badOutput(String((result["result"] as? String ?? "").prefix(500))))
        }
        return .success(Output(summary: s.summary, notes: s.notes, findings: s.findings,
                               costUSD: result["total_cost_usd"] as? Double))
    }
}

/// 평가 지시문(`prompt.md`). 앱이 매번 쓴다. 버전을 올리면 `EvalSpec.promptVersion` 도 올린다.
nonisolated enum EvalPrompt {

    static func render(referenceDir: String) -> String {
        """
        너는 이 사람의 작업을 **사후 평가하는 감시자**다. 작업 방식의 코치이지, 코드 품질 검증자가 아니다.
        아무것도 고치지 않는다(쓰기 툴이 없다). 다이제스트에 없는 것으로 코드 품질을 단정하지 않는다.
        이 사람은 맥에서 안드로이드(Compose) · iOS(SwiftUI) · 백엔드 레포를 오가며 Claude Code 로 일하고,
        멀티 에이전트 앱 "두레"(레포별 터미널 페인 + 조율자 에이전트가 배분)를 직접 만들어 쓴다.
        목적: ① 두레를 실제 작업에 맞게 고칠 근거 ② 작업 습관 · 프롬프트 · 설정 개선 ③ 두레의 토큰 오버헤드 판단.

        ## 읽을 것

        1. `digest.md` — 이 작업. 묶음은 레포 · 브랜치로 **자동 추정**한 것이다.
        2. `backlog.md` — 이미 쌓인 지적. **같은 문제면 그 key 를 그대로** 쓴다. 새 문제일 때만 새 key(소문자 영문 · 숫자 · 하이픈 3~60자).
        3. 기준 문서: `\(referenceDir)/practices.md`(습관 채점표 · 설정 문법) · `\(referenceDir)/tools.md`(다른 도구 · Claude Code 내장 기능) · `\(referenceDir)/skills-mcp.md`(스킬 · MCP).
           문서 머리의 재검토 기한이 지났으면 "자료가 오래됐을 수 있다" 고 `notes` 에 적는다.
        4. 필요할 때만: `digest.md` 6절의 참조 경로.

        ## 무엇을 보나

        | group | 본다 |
        |---|---|
        | dure | 두레가 시간을 아꼈나/더 쓰게 했나 · 터미널(두레 밖)에서 한 부분은 왜 밖이었나 · tools.md 의 기능(Claude Code 내장 포함) 중 이 작업에 있었으면 좋았을 것 · 배분 · 큐 · 완료 보고 · **두레가 강제한 승인 절차의 마찰** · 잘 된 것(works_well) |
        | habit | 프롬프트: 목표 · 맥락 · 완료 조건 누락, 재지시와 그 원인, 한 번에 너무 많이/적게 맡김. 작업 방식: 같은 설명 반복(→ CLAUDE.md), 세션 분할 |
        | tooling | CLAUDE.md 에 넣을 문구 · 추천 스킬 · MCP(설치됨 / 마켓플레이스 / 외부 구별) · 좁은 allow 규칙 |
        | kind `cost` | `digest.md` 의 토큰 절 — 기준선 대비 배수 · 조율자 몫 · 세션 고정비 · 서브에이전트 비중. 두레 탓이면 group dure, 습관 탓이면 habit. 표본이 부족하면 판단하지 않는다 |

        ## 규칙

        - 모든 지적에 evidence 1개 이상: `event` = 턴 머리(조율자 줄 포함)의 `e:` 뒤 8자, `quote` = 그 턴의 프롬프트나 답 끝에서 **그대로 복사**한 6자 이상의 글. 앱이 원문과 대조해 틀린 근거는 버린다.
        - 근거 없는 일반론 금지. 확신이 낮으면 `confidence: low`. 근거가 없으면 지적하지 말고 `notes` 에 "근거 부족" 으로 쓴다. 칭찬을 억지로 찾지 않는다.
        - **"원인 미확인 지연" 은 승인 시간이 아니다.** 그것만으로 승인 문제를 지적하거나 allow 규칙을 권하지 않는다.
          allow 규칙은 근거에 **정확한 명령 · 대상 · 서브커맨드**가 있을 때만, 좁게(`Bash(git -C /절대/경로 status *)` 처럼) 제안한다. `Bash(git -C *)` 같은 넓은 규칙은 쓰기까지 연다 — 권하지 않는다.
        - 반복 읽기 · 테스트 실패 · 중단은 자동으로 낭비가 아니다(새 세션 맥락 복구 · TDD red · 방향 수정). 맥락으로 판단한다.
        - 두레가 강제한 절차(조율자의 "진행" 확인 등)를 사람의 습관 문제로 지적하지 않는다 — 그건 dure 지적이다.
        - 이 사람은 커밋 · push · 브랜치 · 이슈 생성을 직접 한다. 자동화를 권하지 않는다.
        - severity: 3 = 이번 작업에서 시간을 크게 잃음 · 2 = 반복되면 아픔 · 1 = 사소. 지적은 많아야 12개, 중요한 순서로.
        - `apply_text` 는 그대로 복사해 쓸 수 있을 때만.

        ## 출력 (스키마대로)

        - `summary`: 3~5줄 한국어. `notes`: 근거 부족 · 자료 한계 · 참고(선택). `findings`: 위 규칙대로.
        """
    }
}

/// 리포트는 **검증된 지적으로 앱이 렌더한다**(리뷰 P1-E) — 모델의 자유 서술이 검증을 우회하지 못하게.
nonisolated enum ReportRenderer {

    static func render(title: String, summary: String, notes: String?, findings: [ValidatedFinding], rejected: Int) -> String {
        var o = "# \(title)\n\n## 요약\n\n\(summary)\n"
        let sections: [(String, (ValidatedFinding) -> Bool)] = [
            ("두레", { $0.group == "dure" && $0.kind != "works_well" }),
            ("프롬프트 · 작업 방식", { $0.group == "habit" && $0.kind != "works_well" }),
            ("설정 · 도구", { $0.group == "tooling" && $0.kind != "works_well" }),
            ("지킬 것", { $0.kind == "works_well" }),
        ]
        for (name, belongs) in sections {
            let fs = findings.filter(belongs)
            guard !fs.isEmpty else { continue }
            o += "\n## \(name)\n"
            for f in fs {
                o += "\n### \(f.title)\n\n"
                o += "심각도 \(f.severity)\(f.confidence == "low" ? " · 확신 낮음" : "")\(f.kind == "cost" ? " · 토큰" : "")\n\n"
                o += f.detail + "\n"
                if let s = f.suggestion, !s.isEmpty { o += "\n- 제안: \(s)\n" }
                if let a = f.applyText, !a.isEmpty { o += "- 적용: `\(a)`\n" }
                for e in f.evidence {
                    o += "- 근거: \(e.display) · `\(e.sessionId.prefix(8))` · e:\(e.eventId.prefix(8)) — “\(e.quote)”\n"
                }
            }
        }
        if let notes, !notes.isEmpty { o += "\n## 참고\n\n\(notes)\n" }
        if rejected > 0 { o += "\n---\n검증에서 버린 지적 \(rejected)개(근거가 원문과 맞지 않거나 형식이 틀렸다).\n" }
        return o
    }
}
