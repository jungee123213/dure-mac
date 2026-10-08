import Foundation
import GRDB
import Testing
@testable import Dure

/// 이슈 #12 · D-26 — 워크스페이스 관리의 DB 쪽.
/// **급소는 삭제다.** 외래키 연쇄로 사용량 기록까지 지워지므로, 막아야 할 때 못 막으면
/// 되돌릴 길이 없다.
struct WorkspaceOpsTests {

    /// w1 에 레포 r1, r1 에 에이전트 a1 과 세션 cc1. w2 는 빈 워크스페이스.
    static func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "모바일").insert(db)
            try Workspace(id: "w2", name: "웹").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo1",
                     label: nil, model: nil, role: nil).insert(db)
            try Agent(dureSession: "a1", workspaceId: "w1", repoId: "r1", agentKind: "claude",
                      state: .dead, model: nil, startedAt: 0, endedAt: 1).insert(db)
            try db.execute(sql: """
                INSERT INTO cc_session (cc_session_id, dure_session, transcript_path, source, started_at)
                VALUES ('cc1', 'a1', '/t.jsonl', 'startup', 0)
                """)
        }
        return q
    }

    // MARK: - 만들기 · 이름 바꾸기

    @Test func 이름으로_만들고_앞뒤_공백은_뺀다() throws {
        let q = try Self.makeDB()
        let w = try q.write { try WorkspaceOps.create(name: "  백엔드 개편 ", in: $0) }
        #expect(w.name == "백엔드 개편")
        #expect(try q.read { try Workspace.fetchOne($0, key: w.id) }?.name == "백엔드 개편")
    }

    @Test func 기본_CLI_를_함께_저장한다() throws {
        let q = try Self.makeDB()
        let w = try q.write { try WorkspaceOps.create(name: "ws", defaultAgentKind: .codex, in: $0) }
        #expect(try q.read { try Workspace.fetchOne($0, key: w.id) }?.defaultAgentKind == "codex")
    }

    @Test func 빈_이름은_거절한다() throws {
        let q = try Self.makeDB()
        #expect(throws: WorkspaceOps.Refusal.emptyName) {
            try q.write { _ = try WorkspaceOps.create(name: "   ", in: $0) }
        }
        #expect(throws: WorkspaceOps.Refusal.emptyName) {
            try q.write { try WorkspaceOps.rename("w1", to: "", in: $0) }
        }
    }

    @Test func 이름을_바꾼다() throws {
        let q = try Self.makeDB()
        try q.write { try WorkspaceOps.rename("w1", to: "모바일 v2", in: $0) }
        #expect(try q.read { try Workspace.fetchOne($0, key: "w1") }?.name == "모바일 v2")
    }

    // MARK: - 삭제

    /// 확인창에 "무엇이 사라지는지" 를 보여주는 숫자.
    @Test func 삭제_영향을_센다() throws {
        let q = try Self.makeDB()
        let impact = try q.read { try WorkspaceOps.impact(of: "w1", in: $0) }
        #expect(impact == .init(repos: 1, sessions: 1, dispatches: 0))
    }

    @Test func 삭제하면_레포와_기록이_함께_지워진다() throws {
        let q = try Self.makeDB()
        try q.write { try WorkspaceOps.delete("w1", runningWorkspaceIDs: [], in: $0) }
        // #expect 매크로 안의 try 는 read 클로저에서 던지는 것으로 추론되지 않아 값을 먼저 꺼낸다.
        let (ws, repos, agents, sessions) = try q.read { db in
            (try Workspace.fetchOne(db, key: "w1"),
             try Repo.fetchCount(db),
             try Agent.fetchCount(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cc_session"))
        }
        #expect(ws == nil)
        #expect(repos == 0)
        #expect(agents == 0)
        #expect(sessions == 0)
    }

    @Test func 다른_워크스페이스는_남는다() throws {
        let q = try Self.makeDB()
        try q.write { try WorkspaceOps.delete("w1", runningWorkspaceIDs: [], in: $0) }
        #expect(try q.read { try Workspace.fetchOne($0, key: "w2") } != nil)
    }

    /// 0개일 때의 빈 화면을 두지 않는다 (D-26).
    @Test func 마지막_워크스페이스는_지울_수_없다() throws {
        let q = try Self.makeDB()
        try q.write { try WorkspaceOps.delete("w2", runningWorkspaceIDs: [], in: $0) }
        #expect(throws: WorkspaceOps.Refusal.lastWorkspace) {
            try q.write { try WorkspaceOps.delete("w1", runningWorkspaceIDs: [], in: $0) }
        }
    }

    /// **급소.** 돌던 claude 의 agent 행이 연쇄로 지워지면 훅 이벤트가 갈 곳을 잃는다.
    @Test func 실행_중인_페인이_있으면_지울_수_없다() throws {
        let q = try Self.makeDB()
        #expect(throws: WorkspaceOps.Refusal.hasRunningPanes) {
            try q.write { try WorkspaceOps.delete("w1", runningWorkspaceIDs: ["w1"], in: $0) }
        }
        #expect(try q.read { try Repo.fetchCount($0) } == 1)
    }

    @Test func 다른_워크스페이스의_실행_중_페인은_막지_않는다() throws {
        let q = try Self.makeDB()
        try q.write { try WorkspaceOps.delete("w2", runningWorkspaceIDs: ["w1"], in: $0) }
        #expect(try q.read { try Workspace.fetchOne($0, key: "w2") } == nil)
    }

    /// 조율자 기록도 "사라지는 것" 에 센다.
    @Test func 삭제_영향에_조율자_기록도_센다() throws {
        let q = try Self.makeDB()
        try q.write { db in
            try Agent(dureSession: "orch", workspaceId: "w1", repoId: nil, agentKind: "claude",
                      state: .dead, model: nil, startedAt: 0, endedAt: nil).insert(db)
        }
        #expect(try q.read { try WorkspaceOps.impact(of: "w1", in: $0) } == .init(repos: 1, sessions: 2, dispatches: 0))
    }
}
