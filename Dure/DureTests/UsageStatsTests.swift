// Dure/DureTests/UsageStatsTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

/// 이슈 #35 — 대시보드 ③ 사용량 · 툴 에러 상위. 감시자 수집 표로 워크스페이스 레포 단위(터미널 포함)를 센다.
struct UsageStatsTests {

    let db: DatabaseQueue
    let paths = ["/r/app", "/r/api"]

    init() throws {
        db = try Fx.memoryDB()
        try db.write { db in
            try Workspace(id: "w1", name: "모바일").insert(db)
            try Workspace(id: "w2", name: "웹").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/r/app").insert(db)
            try Repo(id: "r2", workspaceId: "w1", path: "/r/api").insert(db)
        }
    }

    // MARK: - 헬퍼

    @discardableResult
    func unit(_ kind: UnitKind, root: String? = nil, cwd: String? = nil, ws: String? = nil) throws -> String {
        let id = UUID().uuidString
        try db.write { db in
            try WorkUnit(id: id, unitKey: id, baseKey: id, kind: kind, repoRoot: root, cwd: cwd, workspaceId: ws,
                         firstTs: 0, lastTs: 0).insert(db)
        }
        return id
    }

    @discardableResult
    func turn(_ unit: String, ts: Int = 1000, input: Int = 0, creation: Int = 0, output: Int = 0,
              cacheRead: Int = 0, sidechain: Int = 0) throws -> String {
        let id = UUID().uuidString
        try db.write { db in
            try ObsTurn(id: id, unitId: unit, eventId: id, ccSessionId: "s", transcriptPath: "/t", lineNo: 1,
                        origin: .terminal, promptKind: .human, ts: ts, prompt: "x",
                        tokensInput: input, tokensOutput: output, tokensCacheCreation: creation,
                        tokensCacheRead: cacheRead, sidechainTokens: sidechain).insert(db)
        }
        return id
    }

    func tool(_ turn: String, _ name: String = "Read", ts: Int = 1000, error: Bool = false, head: String? = nil,
              denied: Bool = false) throws {
        try db.write { db in
            try ObsTool(turnId: turn, transcriptPath: "/t", toolUseId: UUID().uuidString, name: name, startedTs: ts,
                        isError: error, errorHead: head, denied: denied).insert(db)
        }
    }

    func summary(since: Int? = nil) throws -> UsageStats.Summary {
        try db.read { try UsageStats.compute(workspaceID: "w1", repoPaths: paths, since: since, in: $0) }
    }

    // MARK: - 규칙

    @Test func 레포_범위는_정확히_일치하거나_하위_루트() {
        #expect(UsageStats.belongs(repoRoot: "/r/app", to: "/r/app"))
        #expect(UsageStats.belongs(repoRoot: "/r/app/module", to: "/r/app"))
        #expect(!UsageStats.belongs(repoRoot: "/r/app-old", to: "/r/app"))
        #expect(!UsageStats.belongs(repoRoot: "/r", to: "/r/app"))
    }

    @Test func 에러_출처는_MCP_면_서버() {
        #expect(UsageStats.errorSource(tool: "mcp__plugin_figma_figma__get_screenshot") == "plugin_figma_figma")
        #expect(UsageStats.errorSource(tool: "mcp__dure__dispatch") == "dure")
        #expect(UsageStats.errorSource(tool: "Read") == "Read")
    }

    @Test func 사람_거절과_종료_코드뿐인_Bash() {
        #expect(UsageStats.isHumanRejection("The user doesn't want to proceed with this tool use. The tool use was rejected"))
        #expect(!UsageStats.isHumanRejection("Permission for this action was denied by the Claude Code auto mode classifier."))
        #expect(!UsageStats.isHumanRejection(nil))
        #expect(UsageStats.isBareExitCode(tool: "Bash", head: "Exit code 1"))
        #expect(UsageStats.isBareExitCode(tool: "Bash", head: "Exit code 128"))
        #expect(!UsageStats.isBareExitCode(tool: "Bash", head: "Exit code 1: no such file"))
        #expect(!UsageStats.isBareExitCode(tool: "Read", head: "Exit code 1"))
        #expect(!UsageStats.isBareExitCode(tool: "Bash", head: nil))
    }

    @Test func 기간_경계는_로컬_자정() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let now = 1_793_000_000                                   // 2026-10-26 16:33:20 KST
        #expect(UsageStats.Period.today.since(now: now, timeZone: seoul) == 1_792_940_400)   // 10-26 00:00 KST
        #expect(UsageStats.Period.week.since(now: now, timeZone: seoul) == 1_792_422_000)    // 10-20 00:00 KST
        #expect(UsageStats.Period.all.since(now: now, timeZone: seoul) == nil)
    }

    @Test func 짧은_숫자() {
        #expect(UsageStats.compact(999) == "999")
        #expect(UsageStats.compact(12_345) == "12.3K")
        #expect(UsageStats.compact(1_234_567) == "1.2M")
    }

    // MARK: - 집계

    @Test func 레포별_토큰은_캐시_읽기를_빼고_서브에이전트를_넣는다() throws {
        try turn(try unit(.issueBranch, root: "/r/app"), input: 10, creation: 20, output: 30, cacheRead: 1000, sidechain: 5)
        try turn(try unit(.defaultBranch, root: "/r/app/module"), input: 1)
        try turn(try unit(.defaultBranch, root: "/r/app-old"), input: 100)
        try turn(try unit(.noGit, cwd: "/r/app"), input: 100)
        try turn(try unit(.orchestrator, cwd: "/ws/w2", ws: "w2"), input: 100)
        try turn(try unit(.orchestrator, cwd: "/ws/w1", ws: "w1"), input: 7)
        let s = try summary()
        #expect(s.byRepoPath["/r/app"]?.tokens == 66)
        #expect(s.byRepoPath["/r/api"] == UsageStats.Usage())
        #expect(s.orchestrator.tokens == 7)
    }

    @Test func usageIncludesCodexTurns() throws {
        let u = try unit(.issueBranch, root: "/r/app")
        try turn(u, input: 10)
        let id = UUID().uuidString
        try db.write { db in
            try ObsTurn(id: id, unitId: u, eventId: id, ccSessionId: "c", transcriptPath: "/t2", lineNo: 1,
                        origin: .terminal, promptKind: .human, ts: 1000, prompt: "x", tokensInput: 5, tokensOutput: 5,
                        agentKind: .codex).insert(db)
        }
        let o = try unit(.orchestrator, ws: "w1")
        let oid = UUID().uuidString
        try db.write { db in
            try ObsTurn(id: oid, unitId: o, eventId: oid, ccSessionId: "c2", transcriptPath: "/t3", lineNo: 1,
                        origin: .dureOrchestrator, promptKind: .human, ts: 1000, prompt: "x", tokensInput: 3,
                        agentKind: .codex).insert(db)
        }
        let s = try summary()
        #expect(s.byRepoPath["/r/app"]?.tokens == 20)
        #expect(s.orchestrator.tokens == 3)
    }

    @Test func 툴_수는_레포별로_센다() throws {
        let a = try turn(try unit(.issueBranch, root: "/r/app"))
        for _ in 0..<3 { try tool(a) }
        try tool(try turn(try unit(.issueBranch, root: "/r/api")))
        let o = try turn(try unit(.orchestrator, ws: "w1"))
        try tool(o); try tool(o)
        let s = try summary()
        #expect(s.byRepoPath["/r/app"]?.tools == 3 && s.byRepoPath["/r/api"]?.tools == 1 && s.orchestrator.tools == 2)
    }

    @Test func 기간은_토큰은_턴_시각_툴은_툴_시각으로_자른다() throws {
        let since = 5000
        let t = try turn(try unit(.issueBranch, root: "/r/app"), ts: since - 10, input: 50)
        try tool(t, ts: since + 5)
        let s = try summary(since: since)
        #expect(s.byRepoPath["/r/app"] == UsageStats.Usage(tokens: 0, tools: 1))
    }

    @Test func 툴_에러는_출처와_첫_줄로_묶고_횟수_다음_최근순() throws {
        let t = try turn(try unit(.issueBranch, root: "/r/app"))
        let limit = "You've reached the Figma MCP tool call limit"
        try tool(t, "mcp__plugin_figma_figma__get_screenshot", error: true, head: limit)
        try tool(t, "mcp__plugin_figma_figma__get_screenshot", error: true, head: limit)
        try tool(t, "mcp__plugin_figma_figma__get_design_context", error: true, head: limit)
        try tool(t, "mcp__plugin_figma_figma__get_metadata", error: true, head: limit)
        try tool(t, "Read", ts: 3000, error: true, head: "pdftoppm is not installed")
        try tool(t, "Read", ts: 3001, error: true, head: "pdftoppm is not installed")
        try tool(t, "Write", ts: 2000, error: true, head: "x")
        try tool(t, "Write", ts: 2001, error: true, head: "x")
        try tool(t, "Edit", error: true, head: nil)
        try tool(t, "Read")                                        // 에러 아님
        let e = try summary().errors
        #expect(e.map(\.source) == ["plugin_figma_figma", "Read", "Write", "Edit"])
        #expect(e[0].count == 4 && e[0].head == limit)
        #expect(e[1].lastTs == 3001 && e[3].head == "")
    }

    @Test func 사람_거절은_빼고_분류기_거부는_남긴다() throws {
        let t = try turn(try unit(.issueBranch, root: "/r/app"))
        try tool(t, "AskUserQuestion", error: true,
                 head: "The user doesn't want to proceed with this tool use. The tool use was rejected", denied: true)
        try tool(t, "Bash", error: true, head: "Permission for this action was denied by the Claude Code auto mode classifier.",
                 denied: true)
        let e = try summary().errors
        #expect(e.map(\.source) == ["Bash"])
    }

    @Test func 종료_코드뿐인_Bash_는_빼고_건수만_센다() throws {
        let t = try turn(try unit(.issueBranch, root: "/r/app"))
        for _ in 0..<3 { try tool(t, "Bash", error: true, head: "Exit code 1") }
        try tool(t, "Bash", error: true, head: "Exit code 2")
        let s = try summary()
        #expect(s.errors.isEmpty && s.bareExitExcluded == 4)
    }

    /// Codex 툴 실패도 같은 규칙 — 사람의 승인 창 거절(`declined`)은 빼고, 출력 없는 셸 실패는 종료 코드뿐으로 센다.
    @Test func codex_거절과_출력_없는_실패는_오류_목록에_없다() throws {
        let t = try turn(try unit(.issueBranch, root: "/r/app"))
        try tool(t, "Bash", error: true, head: CodexObsParser.declinedHead, denied: true)
        try tool(t, "Edit", error: true, head: CodexObsParser.declinedHead, denied: true)
        try tool(t, "Bash", error: true, head: "Exit code 1")
        try tool(t, "Bash", error: true, head: "error: boom")
        let s = try summary()
        #expect(s.errors.map(\.head) == ["error: boom"] && s.bareExitExcluded == 1)
        #expect(!UsageStats.isHumanRejection("Declined by user"))
    }

    @Test func 에러는_상위_10개까지() throws {
        let t = try turn(try unit(.issueBranch, root: "/r/app"))
        for i in 0..<12 { try tool(t, "Read", error: true, head: "e\(i)") }
        #expect(try summary().errors.count == 10)
    }

    @Test func 다른_워크스페이스_레포와_범위_밖은_에러에도_안_들어간다() throws {
        try tool(try turn(try unit(.issueBranch, root: "/r/other")), "Read", error: true, head: "x")
        try tool(try turn(try unit(.orchestrator, ws: "w2")), "Read", error: true, head: "y")
        #expect(try summary().errors.isEmpty)
    }
}
