import Foundation
import GRDB
import Testing
@testable import Dure

struct MigrationV11Tests {

    /// v11 — 턴을 돌린 CLI. 이미 쌓인 턴은 전부 Claude 것이다.
    @Test func addsAgentKindDefaultClaude() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v10_rate_limit")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO work_unit (id, unit_key, base_key, kind, first_ts, last_ts)
                    VALUES ('u1', 'k|g0', 'k', 'no_git', 1, 1);
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin,
                                      prompt_kind, ts, prompt)
                    VALUES ('t1', 'u1', 'e1', 's1', '/x.jsonl', 1, 'terminal', 'human', 1, '옛 턴');
                """)
        }
        #expect(try q.read { try $0.columns(in: "obs_turn").map(\.name) }.contains("agent_kind") == false)
        try AppDatabase.migrator.migrate(q)
        let old = try q.read { try #require(try ObsTurn.fetchOne($0, key: "t1")) }
        #expect(old.agentKind == .claude)

        var codex = old
        codex.id = "t2"; codex.eventId = "e2"; codex.agentKind = .codex
        try q.write { try codex.insert($0) }
        #expect(try q.read { try String.fetchOne($0, sql: "SELECT agent_kind FROM obs_turn WHERE id = 't2'") } == "codex")
        // 열 없이 넣는 옛 경로(기본값)도 claude.
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin,
                                      prompt_kind, ts, prompt)
                    VALUES ('t3', 'u1', 'e3', 's1', '/x.jsonl', 2, 'terminal', 'human', 2, '');
                """)
        }
        #expect(try q.read { try String.fetchOne($0, sql: "SELECT agent_kind FROM obs_turn WHERE id = 't3'") } == "claude")
    }
}
