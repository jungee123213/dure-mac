// Dure/DureTests/ObserverStoreTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

/// 스토어는 메인액터. `start()` 는 테스트 호스트에서 아무것도 하지 않으므로 개별 동작만 본다.
@MainActor
struct ObserverStoreTests {

    let db: DatabaseQueue
    let dirs: ObserverDirs

    init() throws {
        db = try Fx.memoryDB()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("obsstore-\(UUID().uuidString)")
        dirs = ObserverDirs(root: tmp.appendingPathComponent("observer"), claudeHome: tmp.appendingPathComponent("claude"),
                            workspacesRoot: tmp.appendingPathComponent("ws"), settingsDir: tmp.appendingPathComponent("settings"))
        try db.write { db in
            try WorkUnit(id: "u1", unitKey: "k1", baseKey: "k1", kind: .issueBranch, repoRoot: "/r", branch: "feat/#1/x",
                         githubRepo: "o/r", firstTs: ObsParser.epoch("2026-10-09T09:00:00Z")!,
                         lastTs: ObsParser.epoch("2026-10-09T18:00:00Z")!, humanTurns: 1,
                         editCount: 2).insert(db)
        }
    }

    static let today = ObsParser.epoch("2026-10-10T00:00:00Z")!

    /// `firstStart` 를 주면 감시자가 그때 처음 켜진 것으로 둔다. 안 주면 checkMerges 가 "지금" 을 첫 시작으로 적는다.
    func store(_ runner: FakeRunner = FakeRunner { _ in FakeRunner.ok("") }, firstStart: Int? = nil) -> ObserverStore {
        let d = UserDefaults(suiteName: "obsstore-\(UUID().uuidString)")!
        if let firstStart { d.set(firstStart, forKey: ObserverSettings.firstStartKey) }
        let s = ObserverStore(db: db, runner: runner, resolver: FakeResolver(repos: [:]), defaults: d, dirs: dirs)
        s.now = { Self.today }
        s.reload()
        return s
    }

    @Test func 테스트_호스트에서는_시작하지_않는다() {
        let s = store()
        s.start()
        #expect(s.ghProblem == nil)
        #expect(!FileManager.default.fileExists(atPath: dirs.chatSettings.path))
    }

    @Test func 수동_평가_요청은_한_번만_큐에() throws {
        let s = store()
        s.settings.enabled = false        // pump 가 실행을 시작하지 않게
        s.requestEvaluation("u1")
        s.requestEvaluation("u1")
        let runs = try db.read { try EvaluationRun.fetchAll($0) }
        #expect(runs.count == 1 && runs[0].trigger == .manual && runs[0].status == .queued)
    }

    @Test func 승인_프롬프트를_기록한다() throws {
        store().recordPermissionPrompt(ccSessionID: "s1")
        #expect(try db.read { try ObsPermission.fetchCount($0) } == 1)
    }

    static let merges = FakeRunner { script in
        if script == MergeWatcher.authScript { return FakeRunner.ok("Logged in") }
        if script.contains("gh pr list") {
            return FakeRunner.ok("""
            __DURE_OUT__
            [{"number":3,"url":"old","mergedAt":"2026-09-01T00:00:00Z","headRefOid":"a"},
             {"number":9,"url":"new","mergedAt":"2026-10-09T20:17:08Z","headRefOid":"b"}]
            """)
        }
        return FakeRunner.ok("")
    }

    /// 시나리오 6 · 2 — 옛 PR 이 아니라 작업 시작 뒤 머지된 PR, 그리고 자격이 되면 자동 실행.
    @Test func 머지되면_새_PR_을_기록하고_자동_실행을_큐에() async throws {
        let s = store(Self.merges, firstStart: ObsParser.epoch("2026-10-09T00:00:00Z")!)
        s.settings.dailyCap = 0               // 큐에서 멈추게(평가까지 가지 않게)
        try await db.write { try EvaluationRun(unitId: "u1", trigger: .manual, status: .done, createdAt: 1).insert($0) }  // 수동 중간 평가가 있었다
        await s.checkMerges()
        let u = try await db.read { try #require(try WorkUnit.fetchOne($0, key: "u1")) }
        #expect(u.prNumber == 9 && u.prHead == "b" && u.mergedAt == ObsParser.epoch("2026-10-09T20:17:08Z"))
        let queued = try await db.read { try EvaluationRun.filter(Column("status") == "queued").fetchAll($0) }
        #expect(queued.count == 1 && queued[0].trigger == .auto)
    }

    @Test func 자격이_없으면_PR_만_기록한다() async throws {
        try await db.write { try $0.execute(sql: "UPDATE work_unit SET edit_count = 0") }   // 사람 턴 1 · 수정 0
        let s = store(Self.merges)
        await s.checkMerges()
        #expect(try await db.read { try WorkUnit.fetchOne($0, key: "u1") }?.prNumber == 9)
        #expect(try await db.read { try EvaluationRun.fetchCount($0) } == 0)
    }

    /// 최종 리뷰 F1 — 감시자를 켜기 전에 머지된 PR 은 기록만 하고 자동 평가하지 않는다(첫 수집의 30일 백필).
    @Test func 켜기_전에_머지된_PR_은_기록만_한다() async throws {
        let s = store(Self.merges)              // 첫 시작 = 오늘 > 머지 시각
        await s.checkMerges()
        let u = try await db.read { try #require(try WorkUnit.fetchOne($0, key: "u1")) }
        #expect(u.prNumber == 9 && u.mergedAt != nil)
        #expect(try await db.read { try EvaluationRun.fetchCount($0) } == 0)
    }

    @Test func gh_가_없으면_안내() async {
        let s = store(FakeRunner { _ in CommandResult(status: 127, stdout: Data(), stderr: Data(), timedOut: false) })
        await s.checkMerges()
        #expect(s.ghProblem != nil)
    }

    /// 시나리오 11.
    @Test func 자동_평가를_끄면_대기_중인_자동_실행을_꺼내지_않는다() throws {
        let s = store()
        _ = try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .auto, now: 1, in: $0) }
        s.settings.autoEvaluate = false
        s.pump()
        #expect(s.runningRunID == nil)
        #expect(try db.read { try EvaluationRun.fetchOne($0) }?.status == .queued)
    }

    @Test func 백로그_상태와_피드백() throws {
        try db.write { db in
            try BacklogItem(key: "kkk", bucket: .dure, grp: "dure", kind: "x", title: "t", detail: "d", state: .open).insert(db)
            try EvaluationRun(id: "r1", unitId: "u1", trigger: .manual, status: .done, createdAt: 1, finishedAt: 1).insert(db)
            try Finding(id: "f1", runId: "r1", unitId: "u1", backlogKey: "kkk", grp: "dure", kind: "x", title: "t", detail: "d",
                        evidence: "[]", observedAt: 1, severity: 1, confidence: "high", createdAt: 1).insert(db)
        }
        let s = store()
        s.setState("kkk", .issued, linkedIssue: "dure-mac#24")
        s.setFeedback("f1", .useful)
        let i = try db.read { try #require(try BacklogItem.fetchOne($0, key: "kkk")) }
        #expect(i.state == .issued && i.linkedIssue == "dure-mac#24" && i.usefulCount == 1)
    }

    @Test func 묻기_페인은_격리되고_세션이_기록된다() throws {
        try db.write { try EvaluationRun(id: "r1", unitId: "u1", trigger: .manual, status: .done, createdAt: 1, finishedAt: 1).insert($0) }
        let s = store()
        let script = try #require(s.chatScript(for: "u1"))
        for flag in ["'--safe-mode'", "'--strict-mcp-config'", "'--tools' 'Read,Grep,Glob'", "'--session-id'"] {
            #expect(script.contains(flag), "\(flag)")
        }
        #expect(script.contains("report.md"))
        #expect(try db.read { try ObserverSession.filter(Column("kind") == "chat").fetchCount($0) } == 1)
    }

    /// 최종 리뷰 F4 — 같은 작업의 묻기를 다시 눌러도 새 세션을 만들지 않는다. 닫으면 다시 열 수 있다.
    @Test func 같은_작업의_묻기는_한_번만_연다() throws {
        try db.write { try EvaluationRun(id: "r1", unitId: "u1", trigger: .manual, status: .done, createdAt: 1, finishedAt: 1).insert($0) }
        let s = store()
        s.openChat("u1")
        let first = try #require(s.chat)
        s.openChat("u1")
        #expect(s.chat == first)
        #expect(try db.read { try ObserverSession.filter(Column("kind") == "chat").fetchCount($0) } == 1)
        s.closeChat()
        #expect(s.chat == nil)
        s.openChat("u1")
        #expect(s.chat != nil && s.chat != first)
        #expect(try db.read { try ObserverSession.filter(Column("kind") == "chat").fetchCount($0) } == 2)
    }

    @Test func 완료된_평가가_없으면_묻기를_열지_않는다() {
        let s = store()
        s.openChat("u1")
        #expect(s.chat == nil)
    }

    /// 이슈 #27 Task 4 — merged_at 을 적은 그 쓰기 안에서 머지 뒤 턴을 다음 세대로 옮기고, 자격은 옮긴 뒤 숫자로 본다.
    @Test func 머지를_적으면_머지_뒤_턴을_다음_세대로_옮긴다() async throws {
        try await db.write { db in
            for (i, ts) in ["2026-10-09T10:00:00Z", "2026-10-09T21:00:00Z"].enumerated() {
                try ObsTurn(unitId: "u1", eventId: "e\(i)", ccSessionId: "s", transcriptPath: "/t", lineNo: i,
                            origin: .terminal, promptKind: .human, ts: ObsParser.epoch(ts)!, prompt: "p").insert(db)
            }
        }
        let s = store(Self.merges, firstStart: ObsParser.epoch("2026-10-09T00:00:00Z")!)
        s.settings.dailyCap = 0
        await s.checkMerges()
        let units = try await db.read { try WorkUnit.order(Column("generation")).fetchAll($0) }
        #expect(units.count == 2)
        #expect(units.map(\.humanTurns) == [1, 1])
        #expect(units[0].editCount == 0)
        // 옮긴 뒤 숫자로 자격을 본다 — 머지 전 사람 턴 1 · 수정 0 이면 자동 평가하지 않는다.
        #expect(try await db.read { try EvaluationRun.fetchCount($0) } == 0)
    }
}
