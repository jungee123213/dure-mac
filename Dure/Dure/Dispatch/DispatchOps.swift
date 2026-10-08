import Foundation
import GRDB

/// 단계 4 — `dispatch` · `relay` 표의 연산. `WorkspaceOps` 처럼 `Database` 를 받아 메모리 DB 로 테스트한다.
/// 전달 **판단**은 여기 없다(`DispatchRules`). 여기는 행을 바꾸는 것뿐이다.
enum DispatchOps {

    static func enqueue(workspaceID: String, repoID: String, title: String?, instruction: String,
                        toolUseId: String?, now: Int, in db: Database) throws -> Dispatch {
        // 같은 트랜잭션 안에서 MAX 를 읽어 번호가 겹치지 않는다 (UNIQUE 가 마지막 방어선).
        let last = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM dispatch WHERE workspace_id = ?",
                                    arguments: [workspaceID]) ?? 0
        let d = Dispatch(workspaceId: workspaceID, seq: last + 1, repoId: repoID, title: title,
                         instruction: instruction, state: .queued, toolUseId: toolUseId,
                         deliveredSession: nil, result: nil, failure: nil, createdAt: now,
                         deliveredAt: nil, doneAt: nil)
        try d.insert(db)
        return d
    }

    /// 그 레포의 큐. 선입선출.
    static func queued(repoID: String, in db: Database) throws -> [Dispatch] {
        try Dispatch.filter(Column("repo_id") == repoID && Column("state") == DispatchState.queued.rawValue)
            .order(Column("created_at"), Column("seq")).fetchAll(db)
    }

    /// 전달했는데 아직 `Stop` 을 못 본 것. 레포마다 많아야 하나다.
    static func outstanding(repoID: String, in db: Database) throws -> Dispatch? {
        try Dispatch.filter(Column("repo_id") == repoID && Column("state") == DispatchState.delivered.rawValue)
            .order(Column("delivered_at"), Column("seq")).fetchOne(db)   // 같은 초에 전달됐으면 번호순
    }

    static func markDelivered(_ id: String, session: String?, now: Int, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .delivered; d.deliveredSession = session; d.deliveredAt = now
        try d.update(db)
    }

    static func markDone(_ id: String, result: String?, now: Int, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .done; d.result = result; d.doneAt = now
        try d.update(db)
    }

    static func markFailed(_ id: String, reason: String, now: Int, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .failed; d.failure = reason; d.doneAt = now
        try d.update(db)
    }

    /// `queued` 만 취소된다. 이미 전달된 것을 취소하면 페인은 일하는데 기록만 사라진다.
    static func cancel(_ id: String, in db: Database) throws -> Bool {
        guard var d = try Dispatch.fetchOne(db, key: id), d.state == .queued else { return false }
        d.state = .cancelled
        try d.update(db)
        return true
    }

    @discardableResult
    static func bumpAttempts(_ id: String, in db: Database) throws -> Int {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return 0 }
        d.attempts += 1
        try d.update(db)
        return d.attempts
    }

    /// 앱 시작 때. `delivered` 인 채 남은 것은 `Stop` 을 영영 못 본다 — 닫아야 그 레포 큐가 다시 흐른다.
    static func failUndelivered(reason: String, now: Int, in db: Database) throws -> [Dispatch] {
        let open = try Dispatch.filter(Column("state") == DispatchState.delivered.rawValue).fetchAll(db)
        for d in open { try markFailed(d.id, reason: reason, now: now, in: db) }
        return open
    }

    /// 최신이 먼저 — 대시보드와 조율자 `tasks` 가 읽는다.
    static func history(workspaceID: String, in db: Database) throws -> [Dispatch] {
        try Dispatch.filter(Column("workspace_id") == workspaceID)
            .order(Column("seq").desc).fetchAll(db)
    }

    static func enqueueRelay(workspaceID: String, dispatchID: String?, repoID: String?, kind: RelayKind,
                             body: String, now: Int, in db: Database) throws -> Relay {
        let r = Relay(workspaceId: workspaceID, dispatchId: dispatchID, repoId: repoID, kind: kind,
                      body: body, state: .queued, createdAt: now, deliveredAt: nil)
        try r.insert(db)
        return r
    }

    static func queuedRelays(workspaceID: String, in db: Database) throws -> [Relay] {
        try Relay.filter(Column("workspace_id") == workspaceID && Column("state") == RelayState.queued.rawValue)
            .order(Column("created_at")).fetchAll(db)
    }

    static func markRelaysDelivered(_ ids: [String], now: Int, in db: Database) throws {
        for id in ids {
            guard var r = try Relay.fetchOne(db, key: id) else { continue }
            r.state = .delivered; r.deliveredAt = now
            try r.update(db)
        }
    }

    static func relays(workspaceID: String, in db: Database) throws -> [Relay] {
        try Relay.filter(Column("workspace_id") == workspaceID).order(Column("created_at").desc).fetchAll(db)
    }
}
