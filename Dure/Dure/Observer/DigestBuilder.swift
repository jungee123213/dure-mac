// Dure/Dure/Observer/DigestBuilder.swift
import Foundation

/// 배분 한 건. `Dispatch` 는 MainActor 타입이라 평가 작업(백그라운드)이 못 쓴다 — SQL 로 읽어 이걸로 옮긴다.
nonisolated struct DigestDispatch: Equatable, Sendable {
    var seq: Int
    var repoName: String
    var title: String?
    var instruction: String
    var state: String
    var createdAt: Int
    var deliveredAt: Int?
    var doneAt: Int?
    var result: String?
}

nonisolated struct DigestInput: Sendable {
    var unit: WorkUnit
    var turns: [ObsTurn]
    var tools: [ObsTool]
    var permissions: [ObsPermission] = []
    var orchestratorTurns: [ObsTurn] = []
    var dispatches: [DigestDispatch] = []
    var diffStat: String? = nil
    var references: [String] = []
    var missingTranscripts: Set<String> = []
    /// Task 13 — 토큰 나눔과 같은 레포 터미널 전용 기준선. nil 이면 "토큰" 절을 쓰지 않는다.
    var tokens: TokenAccounting.Breakdown? = nil
    var baseline: TokenAccounting.Baseline? = nil
    var timeZone: TimeZone = .current
}

/// `digest.md`. 스펙 v2 4절. **평가자가 읽는 유일한 본문**이라 근거의 주소(`e:` 이벤트 앞 8자)를 일정하게 단다.
nonisolated enum DigestBuilder {

    static let charLimit = 90_000
    static let edgeTurns = 50

    static func shortEvent(_ id: String) -> String { String(id.prefix(8)) }

    /// 턴 번호(T · O)의 기준 정렬. `EvidenceIndex` 도 이걸 써야 화면 번호와 저장된 번호가 맞는다.
    static func ordered(_ turns: [ObsTurn]) -> [ObsTurn] {
        turns.sorted { ($0.ts, $0.lineNo) < ($1.ts, $1.lineNo) }
    }

    /// 한도를 넘으면 ① 프롬프트 300자 ② 처음 · 끝 50턴만 — 의도(시작)와 결과(끝)를 남기고 가운데를 버린다.
    static func render(_ i: DigestInput) -> String {
        let a = body(i, promptLimit: 1500, windowed: false)
        if a.count <= charLimit { return a }
        let b = body(i, promptLimit: 300, windowed: false)
        if b.count <= charLimit { return b }
        let c = body(i, promptLimit: 300, windowed: true)
        return c.count <= charLimit ? c : String(c.prefix(charLimit))
    }

    static func originLabel(_ o: TurnOrigin) -> String {
        switch o {
        case .dureRepo: "두레 레포 페인"
        case .dureOrchestrator: "조율자"
        case .terminal: "터미널"
        }
    }

    private static func clock(_ ts: Int, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + " …(\(s.count - n)자 생략)"
    }

    private static func quote(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    static func body(_ i: DigestInput, promptLimit: Int, windowed: Bool) -> String {
        let u = i.unit, tz = i.timeZone
        let turns = ordered(i.turns)
        let number = Dictionary(uniqueKeysWithValues: turns.enumerated().map { ($1.id, $0 + 1) })
        let toolsByTurn = Dictionary(grouping: i.tools, by: \.turnId)
        let permByTurn = Signals.permissionsByTurn(turns: turns, permissions: i.permissions)
        var o = "# 작업 다이제스트 — \(u.title)\n\n## 1. 메타\n\n"
        o += "- 묶음: 레포 · 브랜치로 **자동 추정 묶음**이다(다른 작업이 섞였거나 빠졌을 수 있다)\n"
        o += "- 종류: \(u.kind.rawValue) · 위치: `\(u.repoRoot ?? u.cwd ?? "?")`\n"
        if let b = u.branch { o += "- 브랜치: `\(b)`\n" }
        if let n = u.issueNo { o += "- 이슈: #\(n)\(u.githubRepo.map { " (\($0))" } ?? "")\n" }
        o += "- 기간: \(clock(u.firstTs, tz)) ~ \(clock(u.lastTs, tz))\n"
        if let pr = u.prNumber {
            o += "- PR #\(pr)\(u.prUrl.map { " \($0)" } ?? "")\(u.mergedAt.map { " · 머지 \(clock($0, tz))" } ?? "")\n"
        }
        if let d = i.diffStat { o += "- 변경: \(d)\n" }
        o += "- 사람 턴 \(u.humanTurns) · 배분 받은 턴 \(u.peerTurns) · 파일 수정 툴 \(u.editCount)회 · 전체 턴 \(turns.count)\n"
        let claudeTurns = turns.filter { $0.agentKind == .claude }.count, codexTurns = turns.count - claudeTurns
        if claudeTurns > 0 && codexTurns > 0 { o += "- CLI: claude \(claudeTurns)턴 · codex \(codexTurns)턴\n" }
        let sessions = Dictionary(grouping: turns, by: \.ccSessionId)
        o += "\n세션:\n"
        for (sid, ts) in sessions.sorted(by: { $0.value[0].ts < $1.value[0].ts }) {
            var line = "- `\(sid.prefix(8))` · \(originLabel(ts[0].origin)) · 턴 \(ts.count)"
            if let e = ts[0].entrypoint { line += " · \(e)" }
            if let m = ts.compactMap(\.model).last { line += " · \(m)" }
            if i.missingTranscripts.contains(ts[0].transcriptPath) { line += " · (원본 삭제됨)" }
            o += line + "\n"
        }

        o += "\n## 2. 턴 타임라인\n\n근거를 달 때는 턴 머리(3절의 조율자 줄 포함)의 `e:` 뒤 8자를 `event` 로, 그 턴의 프롬프트나 답 끝에서 **그대로 복사한** 글을 `quote` 로 쓴다.\n\n"
        let n = turns.count
        for (idx, t) in turns.enumerated() {
            if windowed, n > edgeTurns * 2 {
                if idx == edgeTurns { o += "… T\(edgeTurns + 1)~T\(n - edgeTurns) 생략 (\(n - edgeTurns * 2)턴) …\n\n" }
                if idx >= edgeTurns && idx < n - edgeTurns { continue }
            }
            var head = "### T\(idx + 1) · \(clock(t.ts, tz)) · \(originLabel(t.origin)) · `\(t.ccSessionId.prefix(8))` · e:\(shortEvent(t.eventId))"
            if t.agentKind == .codex { head += " · [codex]" }
            if t.promptKind != .human { head += " · \(t.promptKind.rawValue)" }
            if let ms = t.durationMs { head += " · \(ms / 1000)초" }
            o += head + "\n\n" + quote(clip(t.prompt, promptLimit)) + "\n\n"
            let tt = toolsByTurn[t.id] ?? []
            if !tt.isEmpty { o += "- 툴: \(Signals.summary(tt))\n" }
            if t.sidechainTools > 0 { o += "- 서브에이전트 툴 ×\(t.sidechainTools)\n" }
            var flags: [String] = []
            let denied = tt.filter(\.denied).count, failed = tt.filter { $0.isError && !$0.denied }.count
            let delayed = tt.filter(Signals.isUnexplainedDelay).count
            if denied > 0 { flags.append("거부 \(denied)") }
            if failed > 0 { flags.append("실패 \(failed)") }
            if let p = permByTurn[t.id] { flags.append("실제 승인 프롬프트 \(p)") }
            if delayed > 0 { flags.append("원인 미확인 지연 \(delayed)") }
            if t.interrupted { flags.append("중단") }
            if t.compacted { flags.append("압축") }
            if !flags.isEmpty { o += "- " + flags.joined(separator: " · ") + "\n" }
            if let a = t.answerTail { o += "- 답 끝: \(a.replacingOccurrences(of: "\n", with: " "))\n" }
            o += "\n"
        }

        if !i.orchestratorTurns.isEmpty || !i.dispatches.isEmpty {
            o += "## 3. 조율자 대화 · 배분\n\n"
            // `e:` 를 단다 — 배분 지시가 모호했다 같은 지적의 근거는 조율자 턴에 있다. 번호는 레포 턴과 겹치지 않게 O.
            for (n, t) in ordered(i.orchestratorTurns).enumerated() {
                o += "- O\(n + 1) · \(clock(t.ts, tz)) · 조율자 · e:\(shortEvent(t.eventId)) — "
                    + clip(t.prompt, 300).replacingOccurrences(of: "\n", with: " ") + "\n"
            }
            for d in i.dispatches.sorted(by: { $0.seq < $1.seq }) {
                var line = "- 배분 #\(d.seq) → \(d.repoName) · \(d.state)"
                if let del = d.deliveredAt { line += " · 큐 대기 \(del - d.createdAt)초" }
                if let done = d.doneAt, let del = d.deliveredAt { line += " · 작업 \(done - del)초" }
                o += line + "\n" + quote(clip(d.instruction, promptLimit)) + "\n"
                if let r = d.result {
                    // waiting 의 result 는 완료 요약이 아니라 에이전트의 마지막 응답이다 — 같은 "결과" 로 읽히면 평가자가 완료로 오해한다.
                    let label = d.state == "done" ? "결과" : d.state == "waiting" ? "마지막 응답(응답 대기)" : "기록"
                    o += "  - \(label): \(clip(r, 300).replacingOccurrences(of: "\n", with: " "))\n"
                }
            }
            o += "\n"
        }

        o += "## 4. 신호\n\n"
        let real = permByTurn.values.reduce(0, +)
        if real > 0 { o += "- 실제 승인 프롬프트(두레 훅): \(real)회\n" }
        let delays = Signals.delays(i.tools)
        if !delays.isEmpty {
            o += "- 원인 미확인 지연(10초 초과 — 승인 · 네트워크 · 실행 중 무엇인지 모른다. **allow 규칙의 근거로 쓰지 않는다**):\n"
            for d in delays { o += "    - `\(d.label)` \(d.count)회 · \(d.seconds)초\n" }
        }
        let reads = Signals.repeatedReads(i.tools)
        if !reads.isEmpty { o += "- 반복 읽기: " + reads.map { "`\($0.label)` \($0.count)회" }.joined(separator: " · ") + "\n" }
        let fails = Signals.failures(i.tools)
        if !fails.isEmpty {
            o += "- 실패한 툴:\n"
            for f in fails { o += "    - \(f.tool) `\(f.target)` — \(f.error) (\(f.count)회)\n" }
        }
        let interrupted = turns.filter(\.interrupted).compactMap { number[$0.id] }
        if !interrupted.isEmpty { o += "- 중단: " + interrupted.map { "T\($0)" }.joined(separator: ", ") + "\n" }
        let compacted = turns.filter(\.compacted).count
        if compacted > 0 { o += "- 압축: \(compacted)회\n" }
        o += "- 세션 \(sessions.count)개 · 세션당 턴 " + sessions.values.map { "\($0.count)" }.sorted().joined(separator: "/") + "\n"
        let sm = Signals.skillsAndMCP(i.tools)
        if !sm.isEmpty { o += "- 스킬 · MCP: " + sm.map { "\($0.label)×\($0.count)" }.joined(separator: " · ") + "\n" }

        // 5. 토큰 — 두레의 추가분(조율자 몫)과 기준선 대비 배수. 금액은 쓰지 않는다(구독 — 한도가 문제).
        if let tk = i.tokens {
            func n(_ d: Double?) -> String { d.map { String(format: "%.0f", $0) } ?? "—" }
            o += "\n## 5. 토큰 (청구 기준 — 캐시 읽기 제외)\n\n"
            o += "- 합계 \(tk.total) = 레포 작업 \(tk.repo) · 서브에이전트 \(tk.subagent) · 조율자 몫 \(tk.orchestrator)"
                + " (\(String(format: "%.0f%%", tk.orchestratorShare * 100)))\n"
            o += "- 세션 고정비(세션마다 첫 턴의 캐시 생성) \(tk.sessionStart) · 캐시 읽기 \(tk.cacheRead)\n"
            o += "- 턴당 \(n(tk.perTurn)) · 변경 줄당 \(n(tk.perLine))\n"
            if let b = i.baseline {
                if b.isReliable {
                    o += "- 기준선(같은 레포 · 터미널 전용 이슈 작업 \(b.samples)개 중앙값): 턴당 \(n(b.perTurn)) · 변경 줄당 \(n(b.perLine))"
                    if let r = TokenAccounting.ratio(tk.perTurn, b.perTurn) { o += " → 이번 작업 턴당 \(String(format: "%.1f", r))배" }
                    o += " (줄당은 표본 \(b.perLineSamples)개)"
                    o += "\n"
                } else {
                    o += "- 기준선: 같은 레포 터미널 전용 이슈 작업이 \(b.samples)개뿐이라 판단 보류\n"
                }
            }
            let costly = turns.filter { $0.tokensHeadline + $0.sidechainTokens > 0 }
                .sorted { $0.tokensHeadline + $0.sidechainTokens > $1.tokensHeadline + $1.sidechainTokens }.prefix(5)
            if !costly.isEmpty {
                o += "- 비싼 턴: " + costly.compactMap { t in number[t.id].map { "T\($0) \(t.tokensHeadline + t.sidechainTokens)" } }
                    .joined(separator: " · ") + "\n"
            }
            var byModel: [String: Int] = [:]
            for t in turns { if let m = t.model { byModel[m, default: 0] += t.tokensHeadline } }
            if !byModel.isEmpty {
                o += "- 모델별: " + byModel.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ") + "\n"
            }
        }

        if !i.references.isEmpty {
            o += "\n## 6. 참조 경로 (필요할 때만 읽는다)\n\n"
            for r in i.references { o += "- \(r)\(i.missingTranscripts.contains(r) ? " (원본 삭제됨)" : "")\n" }
        }
        return o
    }
}
