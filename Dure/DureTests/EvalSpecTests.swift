// Dure/DureTests/EvalSpecTests.swift
import Foundation
import Testing
@testable import Dure

extension Fx {
    /// `claude -p --output-format stream-json --verbose` 출력 모양(2026-10-10 실측): 첫 줄 system/init, 마지막 줄 result.
    static func claudeStream(_ structured: [String: Any]?, tools: [String] = ["Glob", "Grep", "Read", "StructuredOutput"],
                             mcp: [[String: Any]] = [], isError: Bool = false, cost: Double = 0.42,
                             noise: String = "Now using node v24") -> String {
        let initLine = json(["type": "system", "subtype": "init", "tools": tools, "mcp_servers": mcp, "session_id": "sid"])
        var result: [String: Any] = ["type": "result", "subtype": isError ? "error_during_execution" : "success",
                                     "is_error": isError, "result": isError ? "boom" : "", "total_cost_usd": cost]
        if let structured { result["structured_output"] = structured }
        return [noise, initLine, json(["type": "assistant", "message": ["content": []]]), json(result)].joined(separator: "\n") + "\n"
    }
}

struct EvalSpecTests {

    static let good: [String: Any] = [
        "summary": "포팅은 잘 됐다", "notes": "토큰 기준선 표본 부족",
        "findings": [["group": "dure", "kind": "friction", "key": "sibling-repo-read", "title": "iOS 페인이 안드로이드를 못 읽음",
                      "detail": "d", "evidence": [["event": "e1a2b3c4", "quote": "#288 을 iOS 로"]], "severity": 3,
                      "confidence": "high", "apply_text": "--add-dir /r/android"]],
    ]

    func result(_ stdout: String, status: Int32 = 0, stderr: String = "", timedOut: Bool = false) -> CommandResult {
        CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: timedOut)
    }

    @Test func 정상_결과() throws {
        let out = try EvalSpec.interpret(result(Fx.claudeStream(Self.good))).get()
        #expect(out.summary == "포팅은 잘 됐다" && out.notes == "토큰 기준선 표본 부족")
        #expect(out.findings.map(\.key) == ["sibling-repo-read"])
        #expect(out.findings[0].applyText == "--add-dir /r/android")
        #expect(out.costUSD == 0.42)
    }

    /// Review Focus 1 — CLI 가 바뀌어 격리가 깨지면 조용히 넘어가지 않는다.
    @Test func 격리가_깨진_실행은_실패() {
        guard case .failure(.unsafeSession) = EvalSpec.interpret(result(Fx.claudeStream(Self.good, tools: ["Read", "Bash"]))) else {
            Issue.record("Bash 가 있는데 통과"); return
        }
        guard case .failure(.unsafeSession) = EvalSpec.interpret(result(Fx.claudeStream(Self.good, mcp: [["name": "figma"]]))) else {
            Issue.record("MCP 가 있는데 통과"); return
        }
    }

    /// 리뷰 P1-E — JSON 이 있어도 종료 코드가 0 이 아니면 실패.
    @Test func 종료_코드가_0_이_아니면_실패() {
        let r = EvalSpec.interpret(result(Fx.claudeStream(Self.good), status: 9, stderr: "killed"))
        #expect(r == .failure(.process(status: 9, stderrTail: "killed")))
    }

    @Test func 시간_초과_모델_오류_형식_오류() {
        #expect(EvalSpec.interpret(result("", timedOut: true)) == .failure(.timedOut))
        #expect(EvalSpec.interpret(result(Fx.claudeStream(nil, isError: true))) == .failure(.modelError("boom")))
        guard case .failure(.badOutput) = EvalSpec.interpret(result(Fx.claudeStream(nil))) else { Issue.record(""); return }
        guard case .failure(.badOutput) = EvalSpec.interpret(result("Now using node\n")) else { Issue.record(""); return }
    }

    @Test func 명령은_격리_플래그와_세션_ID_를_싣는다() {
        let s = EvalSpec.script(runDir: "/Users/me/.dure/observer/units/u 1/runs/r1", sessionID: "11111111-2222-4333-8444-555555555555",
                                addDirs: ["/r/moamap-iOS", "/Users/me/.claude/skills"])
        #expect(s.hasPrefix("cd '/Users/me/.dure/observer/units/u 1/runs/r1' && claude -p "))
        for flag in ["--safe-mode", "--strict-mcp-config", "--tools Read,Grep,Glob",
                     "--session-id '11111111-2222-4333-8444-555555555555'",
                     "--output-format stream-json", "--verbose", "--json-schema '"] {
            #expect(s.contains(flag), "\(flag)")
        }
        #expect(s.contains("--add-dir '/r/moamap-iOS' --add-dir '/Users/me/.claude/skills'"))
        #expect(s.hasSuffix(" < prompt.md"))
        #expect(!s.contains("--model"))
    }

    @Test func 스키마() throws {
        let o = try #require(try JSONSerialization.jsonObject(with: Data(EvalSpec.schemaJSON.utf8)) as? [String: Any])
        #expect((o["required"] as? [String]) == ["summary", "findings"])
        #expect(!EvalSpec.schemaJSON.contains("'"))
        #expect(!EvalSpec.schemaJSON.contains("report_markdown"))     // 리포트는 앱이 렌더한다
    }

    @Test func 지시문() {
        let p = EvalPrompt.render(referenceDir: "/ref")
        for s in ["digest.md", "backlog.md", "/ref/practices.md", "/ref/tools.md", "/ref/skills-mcp.md",
                  "그대로 복사", "allow 규칙", "근거 부족"] {
            #expect(p.contains(s), "\(s)")
        }
        #expect(!p.contains("최소 1개"))         // 근거 없는 칭찬을 강제하지 않는다(리뷰 P2)
    }

    @Test func 리포트는_검증된_지적으로_앱이_렌더한다() {
        let f = ValidatedFinding(group: "dure", kind: "friction", key: "sibling-repo-read", title: "iOS 페인이 안드로이드를 못 읽음",
                                 detail: "설명", suggestion: "레포 페인에 형제 레포 읽기", applyText: "--add-dir /r/android",
                                 evidence: [Evidence(eventId: "e1a2b3c4-aaaa", sessionId: "sess-aaaa-1", turn: 3, quote: "#288 을 iOS 로", ts: 1)],
                                 severity: 3, confidence: "high", observedAt: 1)
        let w = ValidatedFinding(group: "dure", kind: "works_well", key: "status-chip", title: "상태 칩으로 승인 대기를 바로 봄",
                                 detail: "d", suggestion: nil, applyText: nil,
                                 evidence: [Evidence(eventId: "x", sessionId: "s", turn: 5, quote: "승인 대기", ts: 2)],
                                 severity: 1, confidence: "low", observedAt: 2)
        let r = ReportRenderer.render(title: "moamap-iOS · #52", summary: "요약 줄", notes: "근거 부족: 토큰", findings: [f, w], rejected: 2)
        #expect(r.contains("# moamap-iOS · #52") && r.contains("## 요약") && r.contains("요약 줄"))
        #expect(r.contains("## 두레") && r.contains("### iOS 페인이 안드로이드를 못 읽음"))
        #expect(r.contains("T3 · `sess-aaa` · e:e1a2b3c4 — “#288 을 iOS 로”"))
        #expect(r.contains("`--add-dir /r/android`"))
        #expect(r.contains("## 지킬 것") && r.contains("확신 낮음"))
        #expect(r.contains("## 참고") && r.contains("근거 부족: 토큰"))
        #expect(r.contains("검증에서 버린 지적 2개"))
    }

    /// 습관 · 도구 구역도 works_well 을 빼야 한다 — "지킬 것" 에만 한 번 나온다.
    @Test func 습관의_잘된_점은_지킬_것에만_한_번_나온다() {
        let w = ValidatedFinding(group: "habit", kind: "works_well", key: "clear-goal", title: "목표를 분명히 적음",
                                 detail: "d", suggestion: nil, applyText: nil,
                                 evidence: [Evidence(eventId: "x", sessionId: "s", turn: 1, quote: "목표는 이것이다", ts: 1)],
                                 severity: 1, confidence: "high", observedAt: 1)
        let r = ReportRenderer.render(title: "t", summary: "s", notes: nil, findings: [w], rejected: 0)
        #expect(r.components(separatedBy: "### 목표를 분명히 적음").count == 2)
        #expect(r.contains("## 지킬 것") && !r.contains("## 프롬프트 · 작업 방식"))
    }

    /// init 줄 모양이 달라지면(필드 없음 · 원소가 문자열이 아님) 비었다고 읽지 않고 실패한다.
    @Test func init_줄_형식이_다르면_격리_실패() {
        func stream(_ initObj: [String: Any]) -> String {
            [Fx.json(initObj), Fx.json(["type": "result", "is_error": false, "structured_output": Self.good])].joined(separator: "\n") + "\n"
        }
        let noTools: [String: Any] = ["type": "system", "subtype": "init", "mcp_servers": []]
        let objTools: [String: Any] = ["type": "system", "subtype": "init", "tools": [["name": "Bash"]], "mcp_servers": []]
        let noMcp: [String: Any] = ["type": "system", "subtype": "init", "tools": ["Read"]]
        for o in [noTools, objTools, noMcp] {
            guard case .failure(.unsafeSession) = EvalSpec.interpret(result(stream(o))) else { Issue.record("통과함: \(o)"); continue }
        }
        guard case .failure(.badOutput) = EvalSpec.interpret(result(Fx.json(["type": "result"]) + "\n")) else { Issue.record("init 없음 통과"); return }
    }

    /// 이슈 #40 — git 은 이제 사람이 승인하면 에이전트가 한다. 예전 문장은 감시자가 정상 흐름을 지적하게 만든다.
    @Test func git_규칙은_승인_뒤_에이전트다() {
        #expect(EvalSpec.promptVersion == 4)
        let p = EvalPrompt.render(referenceDir: "/r")
        #expect(p.contains("승인하면 에이전트가 한다"))
        #expect(!p.contains("자동화를 권하지 않는다."))
    }
}
