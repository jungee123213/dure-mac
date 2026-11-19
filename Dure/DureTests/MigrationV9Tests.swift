import Foundation
import GRDB
import Testing
@testable import Dure

struct MigrationV9Tests {

    static func seed(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                INSERT INTO dispatch (id, workspace_id, seq, repo_id, instruction, state, created_at)
                    VALUES ('d1', 'w1', 1, 'r1', '지시', 'delivered', 10);
                INSERT INTO relay (id, workspace_id, dispatch_id, repo_id, kind, body, state, created_at)
                    VALUES ('q1', 'w1', 'd1', 'r1', 'question', '질문', 'queued', 11);
                """)
        }
    }

    @Test func 옛_relay_가_남고_answer_표는_비어_있다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v8_dispatch_git")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                INSERT INTO relay (id, workspace_id, repo_id, kind, body, state, created_at)
                    VALUES ('q1', 'w1', 'r1', 'question', '질문', 'queued', 11);
                """)
        }
        try AppDatabase.migrator.migrate(q)
        let (relays, answers) = try q.read { (try Relay.fetchCount($0), try Answer.fetchCount($0)) }
        #expect(relays == 1)
        #expect(answers == 0)
    }

    @Test func 답_한_행이_모든_필드_그대로_왕복된다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try Self.seed(q)
        let a = Answer(id: "a1", workspaceId: "w1", repoId: "r1", dispatchId: "d1", questionId: "q1",
                       body: "답", state: .failed, failure: "소켓", attempts: 2, createdAt: 20, deliveredAt: 21)
        try q.write { try a.insert($0) }
        let got = try q.read { try Answer.fetchOne($0, key: "a1") }
        #expect(got == a)
    }

    @Test func 배분을_지우면_dispatch_id_가_비고_레포를_지우면_답이_사라진다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try Self.seed(q)
        try q.write { db in
            try Answer(id: "a1", workspaceId: "w1", repoId: "r1", dispatchId: "d1", questionId: "q1",
                       body: "답", state: .queued, createdAt: 20).insert(db)
            try db.execute(sql: "DELETE FROM dispatch WHERE id = 'd1'")
        }
        let afterDispatch = try q.read { try Answer.fetchOne($0, key: "a1") }
        #expect(afterDispatch != nil)
        #expect(afterDispatch?.dispatchId == nil)
        try q.write { try $0.execute(sql: "DELETE FROM repo WHERE id = 'r1'") }
        let count = try q.read { try Answer.fetchCount($0) }
        #expect(count == 0)
    }
}
