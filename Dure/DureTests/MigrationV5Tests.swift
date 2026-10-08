import Foundation
import GRDB
import Testing
@testable import Dure

/// 이슈 #16 · 스키마 v5. **이미 세션·토큰 기록이 쌓인 DB 에서 올라가는 것**을 본다.
/// agent 테이블을 다시 만드는 마이그레이션이라, 틀리면 사람의 사용량 기록이 사라진다.
struct MigrationV5Tests {

    /// v4 까지 올린 DB 에 기록을 넣는다. Agent 구조체는 이미 v5 모양이라 SQL 로 넣는다.
    static func v4WithData() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v4_workspace_orchestrator")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모바일');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/repo1');
                INSERT INTO agent (dure_session, repo_id, agent_kind, state, started_at)
                    VALUES ('a1', 'r1', 'claude', 'dead', 10);
                INSERT INTO cc_session (cc_session_id, dure_session, transcript_path, source, started_at)
                    VALUES ('cc1', 'a1', '/t.jsonl', 'startup', 10);
                INSERT INTO token_usage (cc_session_id, message_id, line_no, ts, input, output)
                    VALUES ('cc1', 'm1', 1, 10, 100, 200);
                """)
        }
        return q
    }

    @Test func 기존_에이전트에_워크스페이스가_채워진다() throws {
        let q = try Self.v4WithData()
        try AppDatabase.migrator.migrate(q)
        let a = try q.read { try Agent.fetchOne($0, key: "a1") }
        #expect(a?.workspaceId == "w1")
        #expect(a?.repoId == "r1")
        #expect(a?.state == .dead)
    }

    /// **급소.** 테이블을 다시 만들 때 딸린 세션·토큰 기록이 사라지면 안 된다.
    @Test func 세션과_토큰_기록이_남는다() throws {
        let q = try Self.v4WithData()
        try AppDatabase.migrator.migrate(q)
        // #expect 안의 try 만으로는 클로저가 throws 로 추론되지 않아, 값을 먼저 꺼낸다.
        let (sessions, input, violations) = try q.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cc_session"),
             try Int.fetchOne(db, sql: "SELECT input FROM token_usage WHERE message_id = 'm1'"),
             // 외래키가 새 agent 테이블을 제대로 가리키는가
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
        #expect(sessions == 1)
        #expect(input == 100)
        #expect(violations == 0)
    }

    @Test func 레포_없는_조율자_에이전트를_넣을_수_있다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Agent(dureSession: "orch", workspaceId: "w1", repoId: nil, agentKind: "claude",
                      state: .started, model: nil, startedAt: 0, endedAt: nil).insert(db)
        }
        #expect(try q.read { try Agent.fetchOne($0, key: "orch") }?.repoId == nil)
    }

    /// 조율자 기록도 워크스페이스와 함께 지워진다 (D-26 연쇄).
    @Test func 워크스페이스를_지우면_조율자_기록도_지워진다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Agent(dureSession: "orch", workspaceId: "w1", repoId: nil, agentKind: "claude",
                      state: .dead, model: nil, startedAt: 0, endedAt: nil).insert(db)
            try db.execute(sql: """
                INSERT INTO cc_session (cc_session_id, dure_session, transcript_path, source, started_at)
                VALUES ('cc9', 'orch', '/t.jsonl', 'startup', 0)
                """)
            _ = try Workspace.deleteOne(db, key: "w1")
        }
        let (agents, sessions) = try q.read { db in
            (try Agent.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cc_session"))
        }
        #expect(agents == 0)
        #expect(sessions == 0)
    }
}
