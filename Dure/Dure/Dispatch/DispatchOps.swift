import Foundation
import GRDB

/// 단계 4 — `dispatch` · `relay` 표의 연산. `WorkspaceOps` 처럼 `Database` 를 받아 메모리 DB 로 테스트한다.
/// 전달 **판단**은 여기 없다(`DispatchRules`). 여기는 행을 바꾸는 것뿐이다.
enum DispatchOps {

    static func enqueue(workspaceID: String, repoID: String, title: String?, instruction: String,
                        git: DispatchGitRequest = .none, toolUseId: String?, now: Int, in db: Database) throws -> Dispatch {
        // 같은 트랜잭션 안에서 MAX 를 읽어 번호가 겹치지 않는다 (UNIQUE 가 마지막 방어선).
        let last = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM dispatch WHERE workspace_id = ?",
                                    arguments: [workspaceID]) ?? 0
        var d = Dispatch(workspaceId: workspaceID, seq: last + 1, repoId: repoID, title: title,
                         instruction: instruction, state: .queued, toolUseId: toolUseId,
                         deliveredSession: nil, result: nil, failure: nil, createdAt: now,
                         deliveredAt: nil, doneAt: nil)
        d.gitMode = git.mode; d.issueTitle = git.issueTitle; d.issueBody = git.issueBody
        d.branchHint = git.branchHint; d.baseBranch = git.baseBranch; d.gitScope = git.scope
        if git.mode == .continueWork { d.issueNumber = git.issueNumber; d.branch = git.branch }
        try d.insert(db)
        return d
    }

    /// 그 레포의 큐. 선입선출.
    static func queued(repoID: String, in db: Database) throws -> [Dispatch] {
        try Dispatch.filter(Column("repo_id") == repoID && Column("state") == DispatchState.queued.rawValue)
            .order(Column("created_at"), Column("seq")).fetchAll(db)
    }

    /// 그 페인이 하고 있는 배분 — 전달됐고 아직 `complete` 되지 않은 것(응답 대기 포함, 이슈 #24). 레포마다 많아야 하나다.
    static let openStates = [DispatchState.delivered.rawValue, DispatchState.waiting.rawValue]

    static func outstanding(repoID: String, in db: Database) throws -> Dispatch? {
        try Dispatch.filter(Column("repo_id") == repoID && openStates.contains(Column("state")))
            .order(Column("delivered_at"), Column("seq")).fetchOne(db)   // 같은 초에 전달됐으면 번호순
    }

    /// `complete` 없이 턴이 끝났다. 마지막 답만 남긴다 — 사람이 [완료로 닫기] 를 누르면 이것이 결과가 된다.
    static func markWaiting(_ id: String, lastMessage: String?, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .waiting
        if let lastMessage { d.result = lastMessage }
        try d.update(db)
    }

    /// 기동 프롬프트(argv)로 실은 배분을 그 페인의 첫 세션에 묶는다.
    static func adoptSession(_ id: String, session: String, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.deliveredSession = session
        try d.update(db)
    }

    static func markDelivered(_ id: String, session: String?, now: Int, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .delivered; d.deliveredSession = session; d.deliveredAt = now
        try d.update(db)
    }

    /// `completion` 은 nil 이 아닌 값만 덮는다 — 이어 하기의 이슈 번호가 보고에 없다고 지워지지 않는다.
    static func markDone(_ id: String, result: String?, completion: DispatchCompletion? = nil, now: Int, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: id) else { return }
        d.state = .done; d.result = result; d.doneAt = now
        if let c = completion {
            if let n = c.issueNumber { d.issueNumber = n }
            if let b = c.branch { d.branch = b }
            if let p = c.prNumber { d.prNumber = p }
        }
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

    /// 앱 시작 때. 열린 채(전달됨 · 응답 대기) 남은 것은 영영 닫히지 않는다 — 앱이 꺼지면 페인(PTY)도 죽었다.
    /// 닫아야 그 레포 큐가 다시 흐른다.
    static func failUndelivered(reason: String, now: Int, in db: Database) throws -> [Dispatch] {
        let open = try Dispatch.filter(openStates.contains(Column("state"))).fetchAll(db)
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

    /// 전달로 찍었지만 읽히지 않은 relay 를 큐로 되돌린다(Codex 조율자 턴이 한도로 실패, D-46). 들어온 순서(`created_at`)는 그대로다.
    static func requeueRelays(_ ids: [String], in db: Database) throws {
        for id in ids {
            guard var r = try Relay.fetchOne(db, key: id), r.state == .delivered else { continue }
            r.state = .queued; r.deliveredAt = nil
            try r.update(db)
        }
    }

    /// 최신이 먼저. `created_at` 은 초 단위라 같은 초는 rowid 로 가른다 — 대시보드 카드가 이걸 뒤집어 시간순으로 그린다.
    static func relays(workspaceID: String, in db: Database) throws -> [Relay] {
        try Relay.filter(Column("workspace_id") == workspaceID).order(Column("created_at").desc, Column.rowID.desc).fetchAll(db)
    }

    // MARK: - 조율자 답 (v9)

    /// 그 레포의 미답 질문 — 마지막 **실패 아닌** 답의 `question_id` 가 가리키는 질문보다 rowid 가 큰 `question` relay.
    /// `created_at` 은 초 단위라 같은 초를 못 가른다 — 순서는 rowid 다. 답 하나가 그 전의 미답 질문을 모두 덮는다.
    static func unansweredQuestions(repoID: String, in db: Database) throws -> [Relay] {
        try Relay.fetchAll(db, sql: """
            SELECT * FROM relay
            WHERE repo_id = ? AND kind = ?
              AND rowid > COALESCE((
                  SELECT q.rowid FROM relay q WHERE q.id = (
                      SELECT question_id FROM answer
                      WHERE repo_id = ? AND state != ? AND question_id IS NOT NULL
                      ORDER BY rowid DESC LIMIT 1)), 0)
            ORDER BY rowid
            """, arguments: [repoID, RelayKind.question.rawValue, repoID, AnswerState.failed.rawValue])
    }

    /// 답할 질문이 없으면 nil — 아무것도 쓰지 않는다(`answer` 가 큐를 건너뛰는 배분이 되지 않게).
    static func enqueueAnswer(workspaceID: String, repoID: String, body: String, now: Int, in db: Database) throws -> Answer? {
        guard let q = try unansweredQuestions(repoID: repoID, in: db).last else { return nil }
        let a = Answer(workspaceId: workspaceID, repoId: repoID, dispatchId: q.dispatchId, questionId: q.id,
                       body: body, state: .queued, createdAt: now)
        try a.insert(db)
        return a
    }

    static func queuedAnswers(repoID: String, in db: Database) throws -> [Answer] {
        try Answer.fetchAll(db, sql: """
            SELECT * FROM answer WHERE repo_id = ? AND state = ? ORDER BY created_at, rowid
            """, arguments: [repoID, AnswerState.queued.rawValue])
    }

    static func markAnswerDelivered(_ id: String, now: Int, in db: Database) throws {
        guard var a = try Answer.fetchOne(db, key: id) else { return }
        a.state = .delivered; a.deliveredAt = now
        try a.update(db)
    }

    static func markAnswerFailed(_ id: String, reason: String, in db: Database) throws {
        guard var a = try Answer.fetchOne(db, key: id) else { return }
        a.state = .failed; a.failure = reason
        try a.update(db)
    }

    @discardableResult
    static func bumpAnswerAttempts(_ id: String, in db: Database) throws -> Int {
        guard var a = try Answer.fetchOne(db, key: id) else { return 0 }
        a.attempts += 1
        try a.update(db)
        return a.attempts
    }

    /// 응답 대기 배분을 다시 일하는 중으로. `result` 는 비우지 않는다(설계 3절).
    static func reopen(_ dispatchID: String, in db: Database) throws {
        guard var d = try Dispatch.fetchOne(db, key: dispatchID), d.state == .waiting else { return }
        d.state = .delivered
        try d.update(db)
    }

    /// 최신이 먼저.
    static func answers(workspaceID: String, in db: Database) throws -> [Answer] {
        try Answer.fetchAll(db, sql: "SELECT * FROM answer WHERE workspace_id = ? ORDER BY created_at DESC, rowid DESC",
                            arguments: [workspaceID])
    }
}
