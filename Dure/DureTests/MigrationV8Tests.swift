import Foundation
import GRDB
import Testing
@testable import Dure

struct MigrationV8Tests {

    @Test func 옛_배분이_그대로_남고_새_열은_비어_있다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v7_observer")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                INSERT INTO dispatch (id, workspace_id, seq, repo_id, instruction, state, created_at)
                    VALUES ('d1', 'w1', 1, 'r1', '지시', 'done', 10);
                """)
        }
        try AppDatabase.migrator.migrate(q)
        let d = try q.read { try Dispatch.fetchOne($0, key: "d1") }
        #expect(d?.instruction == "지시")
        #expect(d?.state == .done)
        #expect(d?.gitMode == nil)
        #expect(d?.issueNumber == nil)
    }

    @Test func 새_열이_왕복된다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                """)
        }
        let d = Dispatch(id: "d1", workspaceId: "w1", seq: 1, repoId: "r1", title: "t", instruction: "지시",
                         state: .queued, createdAt: 10,
                         gitMode: .continueWork, issueTitle: "제목", issueBody: "본문", gitScope: .pr,
                         branchHint: "x", baseBranch: "main", issueNumber: 165, branch: "feat/#165/x", prNumber: 42)
        try q.write { try d.insert($0) }
        let got = try q.read { try Dispatch.fetchOne($0, key: "d1") }
        #expect(got == d)
    }
}
