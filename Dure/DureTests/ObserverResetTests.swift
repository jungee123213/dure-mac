// Dure/DureTests/ObserverResetTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct ObserverResetTests {

    let tmp: URL
    let db: DatabaseQueue
    let dirs: ObserverDirs
    let projects: URL
    let config: CollectConfig
    let resolver = FakeResolver(repos: ["/r/ios": RepoInfo(root: "/r/ios", defaultBranch: "main", githubRepo: "o/r")])

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("obsreset-\(UUID().uuidString)")
        dirs = ObserverDirs(root: tmp.appendingPathComponent("observer"), claudeHome: tmp.appendingPathComponent("claude"),
                            workspacesRoot: tmp.appendingPathComponent("ws"), settingsDir: tmp.appendingPathComponent("settings"))
        projects = dirs.projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.units.appendingPathComponent("u1/runs/r1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirs.reference, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dirs.reference.appendingPathComponent("practices.md"))
        db = try Fx.memoryDB()
        config = CollectConfig(projectsDir: dirs.projects, excludes: [], workspacesRoot: "/ws", timeZone: TimeZone(identifier: "UTC")!)
        let lines = [Fx.human("a"), Fx.human("b", ts: "2026-10-10T02:00:00.000Z")].map { $0 + "\n" }.joined()
        try Data(lines.utf8).write(to: projects.appendingPathComponent("s.jsonl"))
    }

    func collect() throws { _ = try ObsCollector.collect(db: db, config: config, resolver: resolver) }

    /// 모든 표에 한 행씩 — 평가 · 지적 · 백로그까지.
    func seedAll() throws {
        try collect()
        try db.write { db in
            let u = try #require(try WorkUnit.fetchOne(db))
            try db.execute(sql: "INSERT INTO evaluation_run (id, unit_id, trigger, status, created_at) VALUES ('r1', ?, 'manual', 'done', 1)", arguments: [u.id])
            try db.execute(sql: "INSERT INTO backlog_item (key, bucket, grp, kind, title, detail, state) VALUES ('k','dure','g','k','t','d','open')")
            try db.execute(sql: """
                INSERT INTO finding (id, run_id, unit_id, backlog_key, grp, kind, title, detail, evidence, observed_at, severity, confidence, created_at)
                VALUES ('f1','r1',?,'k','g','k','t','d','[]',1,1,'high',1)
                """, arguments: [u.id])
            try db.execute(sql: "INSERT INTO obs_permission (id, cc_session_id, ts) VALUES ('p','s1',1)")
            try db.execute(sql: "INSERT INTO observer_session (session_id, kind, created_at) VALUES ('ev','eval',1)")
        }
    }

    func counts() throws -> [String: Int] {
        try db.read { db in
            var r: [String: Int] = [:]
            for t in ObserverReset.tables + ["observer_session", "obs_permission"] {
                r[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0
            }
            return r
        }
    }

    @Test func 비우면_감시자_표가_0행이고_observer_session_만_남는다() throws {
        try seedAll()
        let before = try counts()
        #expect(before["obs_turn"]! > 0 && before["work_unit"]! > 0 && before["finding"] == 1 && before["obs_cursor"]! > 0)
        #expect(try ObserverReset.run(db: db, dirs: dirs) == .done)
        let after = try counts()
        for t in ObserverReset.tables { #expect(after[t] == 0, "\(t)") }
        #expect(after["observer_session"] == 1)
        #expect(after["obs_permission"] == 1)    // 훅이 채운 기록 — jsonl 로 못 복원하니 남긴다
    }

    @Test func units_폴더는_지우고_reference_는_남긴다() throws {
        try seedAll()
        _ = try ObserverReset.run(db: db, dirs: dirs)
        #expect(!FileManager.default.fileExists(atPath: dirs.units.path))
        #expect(FileManager.default.fileExists(atPath: dirs.reference.appendingPathComponent("practices.md").path))
    }

    @Test func 다시_수집하면_같은_단위_수와_턴_수가_나온다() throws {
        try collect()
        let (u0, t0) = try db.read { (try WorkUnit.fetchCount($0), try ObsTurn.fetchCount($0)) }
        _ = try ObserverReset.run(db: db, dirs: dirs)
        try collect()
        let (u1, t1) = try db.read { (try WorkUnit.fetchCount($0), try ObsTurn.fetchCount($0)) }
        #expect(u0 == u1 && t0 == t1 && u0 == 1 && t0 == 2)
    }

    @Test func 평가가_돌고_있으면_거부하고_아무것도_지우지_않는다() throws {
        try seedAll()
        try db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'running'") }
        let before = try counts()
        #expect(try ObserverReset.run(db: db, dirs: dirs) == .refusedRunning)
        #expect(try counts() == before)
        #expect(FileManager.default.fileExists(atPath: dirs.units.path))
    }

    @MainActor
    @Test func 스토어_resetAll_은_첫_시작_시각을_유지하고_다시_모은다() async throws {
        try seedAll()
        let d = UserDefaults(suiteName: "obsreset-\(UUID().uuidString)")!
        d.set(123, forKey: ObserverSettings.firstStartKey)
        let s = ObserverStore(db: db, runner: FakeRunner { _ in FakeRunner.ok("") }, resolver: resolver, defaults: d, dirs: dirs)
        s.settings.enabled = false          // 재수집 틱이 테스트를 흔들지 않게
        s.now = { 5000 }
        let r = await s.resetAll()
        #expect((try? r.get()) == .done)
        #expect(d.integer(forKey: ObserverSettings.firstStartKey) == 5000)    // 평가 이력이 지워졌으니 첫 시작을 당긴다
        let runs = try await db.read { try EvaluationRun.fetchCount($0) }
        #expect(runs == 0)
        #expect(!s.resetting)
    }

    @MainActor
    @Test func 거부되면_첫_시작_시각을_바꾸지_않는다() async throws {
        try seedAll()
        try await db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'running'") }
        let d = UserDefaults(suiteName: "obsreset-\(UUID().uuidString)")!
        d.set(123, forKey: ObserverSettings.firstStartKey)
        let s = ObserverStore(db: db, runner: FakeRunner { _ in FakeRunner.ok("") }, resolver: resolver, defaults: d, dirs: dirs)
        s.settings.enabled = false
        s.now = { 5000 }
        let r = await s.resetAll()
        #expect((try? r.get()) == .refusedRunning)
        #expect(d.integer(forKey: ObserverSettings.firstStartKey) == 123)
    }

    /// 재구성 뒤 옛 머지(옛 첫 시작 이후였던)는 자동 평가 큐에 다시 들어가지 않는다.
    @MainActor
    @Test func 재구성_뒤_지난_머지는_자동_큐에_들어가지_않는다() async throws {
        try collect()
        let d = UserDefaults(suiteName: "obsreset-\(UUID().uuidString)")!
        d.set(1000, forKey: ObserverSettings.firstStartKey)
        let s = ObserverStore(db: db, runner: FakeRunner { _ in FakeRunner.ok("") }, resolver: resolver, defaults: d, dirs: dirs)
        s.settings.enabled = false
        s.now = { 5000 }
        _ = await s.resetAll()
        try collect()
        // 머지는 옛 첫 시작(1000) 이후, 재구성(5000) 이전
        try await db.write { try $0.execute(sql: "UPDATE work_unit SET merged_at = 3000, edit_count = 5") }
        s.settings.enabled = true
        s.settings.autoEvaluate = true
        await s.queueLateEligible()
        let runs = try await db.read { try EvaluationRun.fetchCount($0) }
        #expect(runs == 0)
    }
}
