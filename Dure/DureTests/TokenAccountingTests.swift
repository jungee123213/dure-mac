// Dure/DureTests/TokenAccountingTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct TokenAccountingTests {

    static func turn(_ id: String, unit: String = "u", session: String = "s1", ts: Int, prompt: String = "p",
                     input: Int = 0, output: Int = 0, creation: Int = 0, read: Int = 0, side: Int = 0,
                     origin: TurnOrigin = .terminal, kind: PromptKind = .human) -> ObsTurn {
        var t = ObsTurn(id: id, unitId: unit, eventId: "ev-\(id)", ccSessionId: session, transcriptPath: "/p/\(session)", lineNo: ts,
                        origin: origin, promptKind: kind, ts: ts, prompt: prompt)
        t.tokensInput = input; t.tokensOutput = output; t.tokensCacheCreation = creation; t.tokensCacheRead = read; t.sidechainTokens = side
        return t
    }

    static func dispatch(turn: String, repo: String) -> ObsTool {
        ObsTool(turnId: turn, transcriptPath: "/o", toolUseId: UUID().uuidString, name: "mcp__dure__dispatch", target: repo, startedTs: 0)
    }

    @Test func 조율자_턴의_대상() {
        let t = Self.turn("o1", ts: 0, prompt: "[두레] ‹moamap-iOS› 배분 #7 끝남\n…\n---\n[두레] ‹MoaMap› 질문 (10:00)")
        #expect(TokenAccounting.targets(of: t, tools: [Self.dispatch(turn: "o1", repo: "moamap-iOS")]) == ["moamap-iOS", "MoaMap"])
        #expect(TokenAccounting.targets(of: Self.turn("o2", ts: 0, prompt: "둘 다 어떻게 할까"), tools: []).isEmpty)
    }

    @Test func 작업_하나의_토큰을_나눈다() {
        let unit = WorkUnit(unitKey: "k", baseKey: "k", kind: .issueBranch, repoRoot: "/r/moamap-iOS", branch: "feat/#52/x",
                            firstTs: 10, lastTs: 30, humanTurns: 2, peerTurns: 2, linesChanged: 100)
        let turns = [Self.turn("t1", ts: 10, input: 100, output: 50, creation: 1000, read: 5000, side: 200),
                     Self.turn("t2", ts: 20, input: 10, output: 40),
                     Self.turn("t3", session: "s2", ts: 30, creation: 300)]
        let orch = [Self.turn("o1", unit: "o", session: "orch", ts: 5, input: 100, output: 100),      // 두 레포 → 반
                    Self.turn("o2", unit: "o", session: "orch", ts: 6, input: 50),                    // 상의만 → 없음
                    Self.turn("o3", unit: "o", session: "orch", ts: 31, prompt: "[두레] ‹MOAMAP-IOS› 배분 #7 끝남", output: 60)]
        let tools = [Self.dispatch(turn: "o1", repo: "moamap-iOS"), Self.dispatch(turn: "o1", repo: "MoaMap")]
        let b = TokenAccounting.breakdown(unit: unit, turns: turns, orchestratorTurns: orch, orchestratorTools: tools, repoLabel: nil)
        #expect(b.repo == 1500 && b.subagent == 200 && b.orchestrator == 160 && b.total == 1860)
        #expect(b.sessionStart == 1300 && b.cacheRead == 5000)
        #expect(b.perTurn == 465 && b.perLine == 18.6)
        #expect(abs(b.orchestratorShare - 160.0 / 1860.0) < 0.0001)
    }

    @Test func 라벨로도_맞춘다() {
        #expect(TokenAccounting.names(repoPath: "/x/bookiibookii-ios", label: "iOS") == ["ios", "bookiibookii-ios", "/x/bookiibookii-ios"])
    }

    static func totals(_ tokens: Int, turns: Int = 1, lines: Int? = nil) -> TokenAccounting.UnitTotals {
        .init(unitId: UUID().uuidString, repoRoot: "/r", workspaceId: nil, firstTs: 0, lastTs: 0, tokens: tokens,
              turns: turns, linesChanged: lines, usedDure: false)
    }

    @Test func 기준선은_중앙값이고_표본_3개_미만은_판단_보류() {
        let b = TokenAccounting.baseline([Self.totals(100), Self.totals(300), Self.totals(200, lines: 10)])
        #expect(b.samples == 3 && b.isReliable && b.perTurn == 200 && b.perLine == 20)
        #expect(!TokenAccounting.baseline([Self.totals(1), Self.totals(2)]).isReliable)
        #expect(TokenAccounting.median([1, 2, 3, 4]) == 2.5 && TokenAccounting.median([]) == nil)
        #expect(TokenAccounting.ratio(300, 200) == 1.5 && TokenAccounting.ratio(300, 0) == nil)
    }

    @Test func 레포별로_두레_사용과_터미널_전용을_비교한다() throws {
        let db = try Fx.memoryDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path, label) VALUES ('r1', 'w1', '/r/ios', 'iOS');
                """)
            for (i, tok) in [100, 200, 300].enumerated() {
                try WorkUnit(id: "t\(i)", unitKey: "t\(i)", baseKey: "t\(i)", kind: .issueBranch, repoRoot: "/r/ios",
                             branch: "feat/#\(i)/x", firstTs: 0, lastTs: 0, humanTurns: 1).insert(db)
                try Self.turn("tt\(i)", unit: "t\(i)", session: "ts\(i)", ts: 0, input: tok).insert(db)
            }
            try WorkUnit(id: "d", unitKey: "d", baseKey: "d", kind: .issueBranch, repoRoot: "/r/ios", branch: "feat/#9/y",
                         workspaceId: "w1", firstTs: 1000, lastTs: 2000, peerTurns: 1).insert(db)
            try Self.turn("dt", unit: "d", session: "ds", ts: 1500, input: 400, origin: .dureRepo, kind: .peer).insert(db)
            try WorkUnit(id: "o", unitKey: "o", baseKey: "o", kind: .orchestrator, cwd: "/ws/w1", day: "2026-10-10",
                         workspaceId: "w1", firstTs: 1200, lastTs: 1200).insert(db)
            try Self.turn("ot", unit: "o", session: "os", ts: 1200, input: 100, origin: .dureOrchestrator).insert(db)
            try Self.dispatch(turn: "ot", repo: "iOS").insert(db)
        }
        let rows = try db.read { try TokenAccounting.comparison(in: $0) }
        let r = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(r.terminal.samples == 3 && r.terminal.perTurn == 200)
        #expect(r.dure.samples == 1 && r.dure.perTurn == 500)       // 레포 400 + 조율자 몫 100
        #expect(r.orchestratorShare == 0.2)
        #expect(r.ratio == nil)                                      // 두레 쪽 표본 1개 — 판단 보류
    }

    @Test func 완료_보고를_받은_조율자_턴도_창_안이다() throws {
        let db = try Fx.memoryDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path, label) VALUES ('r1', 'w1', '/r/ios', 'iOS');
                """)
            try WorkUnit(id: "d", unitKey: "d", baseKey: "d", kind: .issueBranch, repoRoot: "/r/ios", branch: "feat/#9/y",
                         workspaceId: "w1", firstTs: 1000, lastTs: 2000, peerTurns: 1).insert(db)
            try Self.turn("dt", unit: "d", session: "ds", ts: 1500, input: 400, origin: .dureRepo, kind: .peer).insert(db)
            try WorkUnit(id: "o", unitKey: "o", baseKey: "o", kind: .orchestrator, cwd: "/ws/w1", day: "2026-10-10",
                         workspaceId: "w1", firstTs: 2500, lastTs: 9000).insert(db)
            // 보고는 레포 작업의 마지막 턴(2000) 뒤에 온다 → 귀속
            try Self.turn("o1", unit: "o", session: "os", ts: 2500, prompt: "[두레] ‹iOS› 배분 #1 끝남", input: 100).insert(db)
            // 상의만 한 턴 · 창(2000+3600) 밖 보고 → 귀속 안 됨
            try Self.turn("o2", unit: "o", session: "os", ts: 3000, prompt: "상의", input: 30).insert(db)
            try Self.turn("o3", unit: "o", session: "os", ts: 9000, prompt: "[두레] ‹iOS› 배분 #2 끝남", input: 70).insert(db)
        }
        let rows = try db.read { try TokenAccounting.comparison(in: $0) }
        #expect(rows.first?.dure.perTurn == 500)                    // 400 + 100
        let un = try db.read { try TokenAccounting.unattributed(in: $0) }
        #expect(un == [.init(workspaceId: "w1", name: "모아맵", tokens: 100)])
    }

    @Test func 줄당_표본_수를_따로_센다() {
        let b = TokenAccounting.baseline([Self.totals(100), Self.totals(300), Self.totals(200, lines: 10)])
        #expect(b.samples == 3 && b.perLineSamples == 1)
    }

    @Test func 두_대상_중_하나만_작업이_있으면_나머지_절반이_귀속_안_됨() throws {
        let db = try Fx.memoryDB()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path, label) VALUES ('r1', 'w1', '/r/ios', 'iOS');
                """)
            try WorkUnit(id: "d", unitKey: "d", baseKey: "d", kind: .issueBranch, repoRoot: "/r/ios", branch: "feat/#9/y",
                         workspaceId: "w1", firstTs: 1000, lastTs: 2000, peerTurns: 1).insert(db)
            try Self.turn("dt", unit: "d", session: "ds", ts: 1500, input: 400, origin: .dureRepo, kind: .peer).insert(db)
            try WorkUnit(id: "o", unitKey: "o", baseKey: "o", kind: .orchestrator, cwd: "/ws/w1", day: "2026-10-10",
                         workspaceId: "w1", firstTs: 1200, lastTs: 1200).insert(db)
            try Self.turn("ot", unit: "o", session: "os", ts: 1200, input: 100, origin: .dureOrchestrator).insert(db)
            try Self.dispatch(turn: "ot", repo: "iOS").insert(db)
            try Self.dispatch(turn: "ot", repo: "Android").insert(db)
        }
        let rows = try db.read { try TokenAccounting.comparison(in: $0) }
        #expect(rows.first?.dure.perTurn == 450)                    // 400 + 100 * 1/2
        let un = try db.read { try TokenAccounting.unattributed(in: $0) }
        #expect(un.first?.tokens == 50)                             // 귀속 50 + 안 된 50 == 100
    }
}
