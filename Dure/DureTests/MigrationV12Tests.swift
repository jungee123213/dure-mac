import Foundation
import GRDB
import Testing
@testable import Dure

/// v12 — 감시자 데이터 정확도(이슈 #60, D-48). 원본이 지워진 턴이 많아 다시 수집하지 않고 DB 에서 고친다.
struct MigrationV12Tests {

    /// u1: Claude 단위(배분 1 · hand-back 2) · u2: Codex 가져오기 사본만 있는 단위 · u3: Codex 직접 친 턴 · u4: 손대지 않는 단위.
    func seeded() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v11_obs_agent_kind")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO work_unit (id, unit_key, base_key, kind, first_ts, last_ts, human_turns, peer_turns, edit_count,
                                       source_revision)
                    VALUES ('u1', 'a|g0', 'a', 'issue_branch', 10, 50, 1, 3, 1, 5),
                           ('u2', 'b|g0', 'b', 'no_git', 100, 100, 2, 0, 0, 2),
                           ('u3', 'c|g0', 'c', 'issue_branch', 10, 20, 1, 0, 0, 1),
                           ('u4', 'd|g0', 'd', 'issue_branch', 10, 20, 1, 1, 0, 7);
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin, prompt_kind,
                                      ts, prompt, agent_kind, tokens_output)
                    VALUES ('h1', 'u1', 'e1', 's1', '/c.jsonl', 1, 'terminal', 'human', 10, '커밋해줘', 'claude', 5),
                           ('p1', 'u1', 'e2', 's1', '/c.jsonl', 2, 'dure_repo', 'peer', 20, '[두레] 배분 #3', 'claude', 5),
                           ('b1', 'u1', 'e3', 's1', '/c.jsonl', 3, 'terminal', 'peer', 30,
                            '[Subagent hand-back] The text below is the final report', 'claude', 5),
                           ('b2', 'u1', 'e4', 's1', '/c.jsonl', 4, 'terminal', 'peer', 40,
                            '[Subagent hand-back] The text below is the final report', 'claude', 5),
                           ('i1', 'u2', 'x:5', 'x', '/r.jsonl', 5, 'terminal', 'human', 100, '커밋해줘', 'codex', 0),
                           ('i2', 'u2', 'x:9', 'x', '/r.jsonl', 9, 'terminal', 'human', 100, '진행', 'codex', 0),
                           ('n1', 'u3', 'y:1', 'y', '/q.jsonl', 1, 'terminal', 'human', 15, '커밋해줘', 'codex', 40),
                           ('d1', 'u4', 'e9', 's9', '/d.jsonl', 1, 'dure_repo', 'peer', 15, '[두레] 배분 #1', 'claude', 9);
                INSERT INTO obs_tool (id, turn_id, transcript_path, tool_use_id, name, started_ts)
                    VALUES ('o1', 'h1', '/c.jsonl', 'tu1', 'Edit', 11);
                """)
        }
        return q
    }

    @Test func hand_back_턴은_알림으로_바꾸고_배분은_그대로() throws {
        let q = try seeded()
        try AppDatabase.migrator.migrate(q)
        let kinds = try q.read { try Row.fetchAll($0, sql: "SELECT id, prompt_kind FROM obs_turn WHERE unit_id = 'u1' ORDER BY id") }
            .map { "\($0["id"] as String)=\($0["prompt_kind"] as String)" }
        #expect(kinds == ["b1=notice", "b2=notice", "h1=human", "p1=peer"])
        let u = try q.read { try #require(try WorkUnit.fetchOne($0, key: "u1")) }
        #expect(u.peerTurns == 1 && u.humanTurns == 1 && u.editCount == 1)
        #expect(u.sourceRevision == 6)
    }

    @Test func 가져온_Codex_턴은_지우고_직접_친_턴은_남긴다() throws {
        let q = try seeded()
        try AppDatabase.migrator.migrate(q)
        let ids = try q.read { try String.fetchAll($0, sql: "SELECT id FROM obs_turn WHERE agent_kind = 'codex' ORDER BY id") }
        // i1 — 앞선 Claude 턴과 프롬프트가 같은 토큰 0 · 툴 0 사본. i2 — 짝이 되는 Claude 턴이 없어 남는다(D-48 의 놓치는 7개).
        // n1 — 프롬프트가 같아도 토큰을 쓴 직접 친 턴이다.
        #expect(ids == ["i2", "n1"])
    }

    @Test func 앞선_Claude_턴이_없으면_사본으로_보지_않는다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v11_obs_agent_kind")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO work_unit (id, unit_key, base_key, kind, first_ts, last_ts) VALUES ('u', 'k|g0', 'k', 'no_git', 1, 1);
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin, prompt_kind,
                                      ts, prompt, agent_kind)
                    VALUES ('codex', 'u', 'x:1', 'x', '/r.jsonl', 1, 'terminal', 'human', 5, '진행', 'codex'),
                           ('claude', 'u', 'e1', 's', '/c.jsonl', 1, 'terminal', 'human', 9, '진행', 'claude');
                """)
        }
        try AppDatabase.migrator.migrate(q)
        // Codex 턴이 Claude 턴보다 먼저다 — 가져온 사본일 수 없다.
        #expect(try q.read { try String.fetchAll($0, sql: "SELECT id FROM obs_turn ORDER BY id") } == ["claude", "codex"])
    }

    @Test func 토큰이나_툴이_있으면_사본으로_보지_않는다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v11_obs_agent_kind")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO work_unit (id, unit_key, base_key, kind, first_ts, last_ts) VALUES ('u', 'k|g0', 'k', 'no_git', 1, 1);
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin, prompt_kind,
                                      ts, prompt, agent_kind, tokens_input)
                    VALUES ('claude', 'u', 'e1', 's', '/c.jsonl', 1, 'terminal', 'human', 1, '진행', 'claude', 3),
                           ('tok', 'u', 'x:1', 'x', '/r.jsonl', 1, 'terminal', 'human', 5, '진행', 'codex', 7),
                           ('tool', 'u', 'x:2', 'x', '/r.jsonl', 2, 'terminal', 'human', 6, '진행', 'codex', 0);
                INSERT INTO obs_tool (id, turn_id, transcript_path, tool_use_id, name, started_ts)
                    VALUES ('o', 'tool', '/r.jsonl', 'c1', 'Bash', 6);
                """)
        }
        try AppDatabase.migrator.migrate(q)
        #expect(try q.read { try String.fetchAll($0, sql: "SELECT id FROM obs_turn ORDER BY id") } == ["claude", "tok", "tool"])
    }

    @Test func 사본만_있던_단위는_지우고_바뀐_단위만_다시_센다() throws {
        let q = try seeded()
        try AppDatabase.migrator.migrate(q)
        let units = try q.read { try WorkUnit.fetchAll($0).sorted { $0.id < $1.id } }
        // u2 는 i2 가 남아 산다. 사람 턴은 다시 세서 1.
        let u2 = try #require(units.first { $0.id == "u2" })
        #expect(u2.humanTurns == 1 && u2.sourceRevision == 3)
        // 바뀌지 않은 u4 는 숫자 · revision 그대로.
        let u4 = try #require(units.first { $0.id == "u4" })
        #expect(u4.peerTurns == 1 && u4.sourceRevision == 7)
    }

    @Test func 턴이_모두_지워진_단위는_평가나_PR_이_없으면_지운다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v11_obs_agent_kind")
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO work_unit (id, unit_key, base_key, kind, first_ts, last_ts, human_turns, pr_number)
                    VALUES ('only', 'k|g0', 'k', 'no_git', 1, 1, 1, NULL),
                           ('pr', 'p|g0', 'p', 'issue_branch', 1, 1, 1, 9),
                           ('c', 'c|g0', 'c', 'no_git', 1, 1, 1, NULL);
                INSERT INTO obs_turn (id, unit_id, event_id, cc_session_id, transcript_path, line_no, origin, prompt_kind,
                                      ts, prompt, agent_kind)
                    VALUES ('claude', 'c', 'e1', 's', '/c.jsonl', 1, 'terminal', 'human', 1, '진행', 'claude'),
                           ('imp1', 'only', 'x:1', 'x', '/r.jsonl', 1, 'terminal', 'human', 5, '진행', 'codex'),
                           ('imp2', 'pr', 'x:2', 'x', '/r.jsonl', 2, 'terminal', 'human', 5, '진행', 'codex');
                """)
        }
        try AppDatabase.migrator.migrate(q)
        #expect(try q.read { try String.fetchAll($0, sql: "SELECT id FROM work_unit ORDER BY id") } == ["c", "pr"])
        let pr = try q.read { try #require(try WorkUnit.fetchOne($0, key: "pr")) }
        #expect(pr.humanTurns == 0)
    }
}
