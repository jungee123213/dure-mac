// Dure/DureTests/MigrationV7Tests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct MigrationV7Tests {

    static func v6WithData() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v6_dispatch_relay")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                INSERT INTO dispatch (id, workspace_id, seq, repo_id, instruction, state, created_at)
                    VALUES ('d1', 'w1', 1, 'r1', '지시', 'done', 10);
                """)
        }
        return q
    }

    static func unit(_ key: String, workspace: String? = nil) -> WorkUnit {
        WorkUnit(id: key, unitKey: key, baseKey: key, kind: .issueBranch, repoRoot: "/repo1", branch: "feat/#1/x",
                 issueNo: 1, workspaceId: workspace, firstTs: 1, lastTs: 2)
    }

    @Test func 배분_기록이_남는다() throws {
        let q = try Self.v6WithData()
        try AppDatabase.migrator.migrate(q)
        #expect(try q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dispatch") } == 1)
    }

    @Test func 모든_감시_표가_왕복된다() throws {
        let q = try Self.v6WithData()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Self.unit("u1", workspace: "w1").insert(db)
            let t = ObsTurn(id: "t1", unitId: "u1", eventId: "ev-1", ccSessionId: "s1", transcriptPath: "/t.jsonl",
                            lineNo: 3, origin: .terminal, promptKind: .human, ts: 5, prompt: "안녕")
            try t.insert(db)
            try ObsUsage(ccSessionId: "s1", messageId: "m1", turnId: "t1", sidechain: false).insert(db)
            try ObsTool(turnId: "t1", transcriptPath: "/t.jsonl", toolUseId: "tu1", name: "Read", startedTs: 6).insert(db)
            try ObsPermission(ccSessionId: "s1", ts: 7).insert(db)
            try ObserverSession(sessionId: "obs-1", kind: "eval", createdAt: 8).insert(db)
            let r = EvaluationRun(id: "r1", unitId: "u1", trigger: .manual, status: .done, createdAt: 9)
            try r.insert(db)
            try BacklogItem(key: "dispatch-x", bucket: .dure, grp: "dure", kind: "friction", title: "t", detail: "d",
                            state: .open).insert(db)
            try Finding(runId: "r1", unitId: "u1", backlogKey: "dispatch-x", grp: "dure", kind: "friction", title: "t",
                        detail: "d", evidence: "[]", observedAt: 5, severity: 2, confidence: "high", createdAt: 10).insert(db)
        }
        let (u, usage, run, f) = try q.read { db in
            (try WorkUnit.fetchOne(db), try ObsUsage.fetchCount(db), try EvaluationRun.fetchOne(db), try Finding.fetchOne(db))
        }
        #expect(u?.sourceRevision == 0 && u?.activity == 0)
        #expect(usage == 1)
        #expect(run?.status == .done && run?.trigger == .manual)
        #expect(f?.feedback == nil)
    }

    @Test func 같은_원장_행은_하나뿐이다() throws {
        let q = try Fx.memoryDB()
        try q.write { db in
            try Self.unit("u1").insert(db)
            try ObsTurn(id: "t1", unitId: "u1", eventId: "e", ccSessionId: "s", transcriptPath: "/t", lineNo: 1,
                        origin: .terminal, promptKind: .human, ts: 1, prompt: "p").insert(db)
            try ObsUsage(ccSessionId: "s", messageId: "m", turnId: "t1", sidechain: false).insert(db)
        }
        #expect(throws: (any Error).self) {
            try q.write { try ObsUsage(ccSessionId: "s", messageId: "m", turnId: "t1", sidechain: true).insert($0) }
        }
    }

    @Test func 워크스페이스를_지우면_연결만_끊긴다() throws {
        let q = try Self.v6WithData()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Self.unit("u1", workspace: "w1").insert(db)
            try db.execute(sql: "DELETE FROM workspace WHERE id = 'w1'")
        }
        let u = try q.read { try WorkUnit.fetchOne($0) }
        #expect(u != nil && u?.workspaceId == nil)
    }

    @Test func 같은_열쇠의_단위와_같은_이벤트의_턴은_하나뿐이다() throws {
        let q = try Fx.memoryDB()
        try q.write { try Self.unit("same").insert($0) }
        #expect(throws: (any Error).self) {
            try q.write { db in
                var u = Self.unit("other"); u.unitKey = "same"
                try u.insert(db)
            }
        }
        try q.write { db in
            try ObsTurn(id: "a", unitId: "same", eventId: "ev", ccSessionId: "s", transcriptPath: "/t", lineNo: 1,
                        origin: .terminal, promptKind: .human, ts: 1, prompt: "p").insert(db)
        }
        #expect(throws: (any Error).self) {
            try q.write { db in
                try ObsTurn(id: "b", unitId: "same", eventId: "ev", ccSessionId: "s", transcriptPath: "/t2", lineNo: 9,
                            origin: .terminal, promptKind: .human, ts: 1, prompt: "p").insert(db)
            }
        }
    }

    @Test func 단위를_지우면_턴_실행_지적이_따라_지워진다() throws {
        let q = try Fx.memoryDB()
        try q.write { db in
            try Self.unit("u").insert(db)
            try ObsTurn(id: "t", unitId: "u", eventId: "e", ccSessionId: "s", transcriptPath: "/t", lineNo: 1,
                        origin: .terminal, promptKind: .human, ts: 1, prompt: "p").insert(db)
            try EvaluationRun(id: "r", unitId: "u", trigger: .auto, status: .done, createdAt: 1).insert(db)
            try BacklogItem(key: "kkk", bucket: .habit, grp: "habit", kind: "prompt", title: "t", detail: "d", state: .open).insert(db)
            try Finding(runId: "r", unitId: "u", backlogKey: "kkk", grp: "habit", kind: "prompt", title: "t", detail: "d",
                        evidence: "[]", observedAt: 1, severity: 1, confidence: "low", createdAt: 1).insert(db)
            try db.execute(sql: "DELETE FROM work_unit")
        }
        let counts = try q.read { db in
            [try ObsTurn.fetchCount(db), try EvaluationRun.fetchCount(db), try Finding.fetchCount(db)]
        }
        #expect(counts == [0, 0, 0])
    }

    @Test func 제목과_활동량() {
        var u = Self.unit("k")
        u.humanTurns = 1; u.peerTurns = 2
        #expect(u.activity == 3)
        #expect(u.title == "repo1 · #1")
        u.kind = .defaultBranch; u.branch = "main"; u.issueNo = nil; u.day = "2026-10-10"
        #expect(u.title == "repo1 · main · 2026-10-10")
        u.kind = .noGit; u.repoRoot = nil; u.cwd = "/Users/me/Desktop"; u.branch = nil
        #expect(u.title == "Desktop · 2026-10-10")
    }
}
