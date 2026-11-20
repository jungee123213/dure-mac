import Foundation
import GRDB

/// 단계 4 — 배분의 흐름을 맡는 유일한 곳. 설계 3절.
///
/// 들어오는 것: 조율자의 `dispatch`(enqueue) · 레포의 `complete`/`report`/`ask`(complete · relay) · 사람의 [완료로 닫기](closeByHuman)
/// · 훅(didStart · didStop · didDie) · 앱 시작(recover).
/// **완료는 레포 에이전트가 `complete` 로 선언한다**(이슈 #24). 턴이 끝난 것(Stop)은 완료가 아니다 — 사람에게 묻고 멈췄을 수 있다.
/// 나가는 것: 받는 페인 종류에 맞는 출구(`PaneMessaging` — Claude 인박스 소켓 · Codex `codex queue`) 또는 기동 프롬프트(`initialPrompt`). 판단은 `DispatchRules`, 행은 `DispatchOps`.
///
/// 스토어의 상태는 `Lookups` 클로저로 받는다 — 스토어는 실제 DB 를 쓰므로 여기서 직접 잡으면 테스트가 안 된다.
///
/// Codex 계정 한도(4단계, D-46): 스토어가 Codex 페인 · Codex 조율자의 뷰에 `limitedUntil` 을 채우면 그쪽으로는 아무것도 보내지
/// 않는다(큐에 남김). 한도로 끊긴 턴에는 Stop 이 없다(j-stage4 2절) — `didHitUsageLimit` 이 끊긴 배분을 기억하고,
/// `didReleaseUsageLimit` 이 그 페인에 "이어서 하라" 를 한 번 보낸 뒤 큐를 전부 흘린다.
@MainActor
final class Dispatcher {

    struct PaneView {
        var started: Bool
        var state: AgentState?
        /// 메시지를 넣을 곳. Claude 는 현재 cc_session_id, Codex 는 서버 소켓 + 스레드 id. 모르면 nil — 큐에 남는다.
        var address: PaneAddress?
        var kind: AgentKind = .claude
        /// Codex 계정 한도로 막혀 있으면 다시 볼 시각. 스토어가 Codex 페인 · Codex 조율자에만 채운다 — Claude 는 늘 nil.
        var limitedUntil: Int? = nil
    }

    struct Lookups {
        var repoPane: (String) -> PaneView
        var orchestratorPane: (String) -> PaneView
        var repoName: (String) -> String
    }

    enum EnqueueOutcome: Equatable {
        case delivered(seq: Int), queuedBusy(seq: Int), queuedNotStarted(seq: Int)
        /// 페인은 놀고 있었는데 소켓에 못 썼다. `queuedBusy` 로 답하면 조율자가 오지 않을 `Stop` 을
        /// 기다리므로 따로 알린다. 재시도는 `retryPending()`(앱 주기 틱)이 맡는다.
        case deliveryFailed(seq: Int, attempts: Int)
        /// 떠 있는 Codex 페인인데 계정 한도로 막혀 있다. `until` 이후 풀리면 저절로 간다.
        case queuedLimited(seq: Int, until: Int)
    }

    /// 조율자 `answer` 의 결과(이슈 #43). `EnqueueOutcome` 과 같은 결에 셋을 더했다 —
    /// 질문이 나온 배분이 이미 닫혀 못 보냄(`dispatchClosed`), 답할 질문이 없어 아무것도 안 씀(`noQuestion`),
    /// 답할 질문은 없지만 아직 안 간 답이 큐에 있어 아무것도 안 씀(`answerPending`).
    enum AnswerOutcome: Equatable {
        case delivered, queuedBusy, queuedNotStarted
        case deliveryFailed(attempts: Int)
        case queuedLimited(until: Int)
        case dispatchClosed(seq: Int)
        case noQuestion
        case answerPending
    }

    private let db: DatabaseQueue
    private let messaging: PaneMessaging
    let lookups: Lookups
    private let now: () -> Int
    /// 조율자에게 묶음을 넣고 그 턴의 `Stop` 을 아직 못 본 워크스페이스. 레포의 `outstanding` 과 같은 가드다 —
    /// 소켓이 시작한 턴에 `UserPromptSubmit` 이 뜨는지 미확인이라 상태(`done`)만 믿으면 조율자가 첫 묶음을
    /// 읽는 중에 다음 묶음이 끼어든다. 메모리에만 둔다 — 앱을 다시 켜면 조율자 세션도 새로 뜬다.
    private var orchestratorAwaitingStop: Set<String> = []
    /// 레포 쪽 같은 가드(이슈 #27). 소켓으로 배분을 **보낸 순간** 넣고 그 턴의 Stop · 새 세션 · 페인 종료에서 뺀다.
    /// `outstanding` 은 `complete` 로 닫히면 사라지지만 그 턴은 아직 돌고 있다 — 페인 상태(`done`)도 소켓 턴에
    /// `UserPromptSubmit` 이 안 뜨면 그대로라 믿을 수 없다. 이 집합이 없으면 이전 턴의 Stop 이 새 배분을 waiting 으로 만든다.
    /// argv 로 실은 배분은 넣지 않는다. 메모리에만 둔다 — 앱을 다시 켜면 `recoverOnLaunch` 가 열린 배분을 닫고 가드는 비어 있다.
    private var repoAwaitingStop: Set<String> = []
    /// Codex 한도로 끊긴 턴에 열려 있던 배분(레포 id → 배분 id). 닫지 않고 두었다가 풀리면 한 번 이어 하게 한다. 메모리에만 —
    /// 앱을 다시 켜면 `recoverOnLaunch` 가 열린 배분을 닫는다.
    private var limitInterrupted: [String: String] = [:]
    /// 이번 막힘에 한도 안내를 이미 보낸 워크스페이스. 막힌 동안의 두 번째 신호는 다시 알리지 않는다. 풀리면 비운다.
    private var limitNoticed: Set<String> = []
    /// 워크스페이스마다 조율자에게 마지막으로 보낸 묶음의 relay id. 그 턴이 한도로 실패하면 묶음은 읽히지 않았다 —
    /// 다시 큐로 돌린다. 그 턴의 Stop(= 읽음) · 페인 종료에서 지운다.
    private var lastOrchestratorBundle: [String: [String]] = [:]
    /// 한도로 끊긴 조율자 턴에서 큐로 되돌린 relay. 다음 묶음이 이것을 실으면 "다시 보낸다" 한 줄을 앞에 붙인다(조율자가
    /// 일부를 이미 읽고 dispatch · answer 했을 수 있다). 실어 보내면 지운다.
    private var resentRelays: Set<String> = []

    init(db: DatabaseQueue, messaging: PaneMessaging, lookups: Lookups,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.db = db; self.messaging = messaging; self.lookups = lookups; self.now = now
    }

    // MARK: - 들어오는 것

    func enqueue(workspaceID: String, repo: Repo, title: String?, instruction: String,
                 git: DispatchGitRequest = .none, toolUseId: String?) throws -> EnqueueOutcome {
        let d = try db.write {
            try DispatchOps.enqueue(workspaceID: workspaceID, repoID: repo.id, title: title,
                                    instruction: instruction, git: git, toolUseId: toolUseId, now: now(), in: $0)
        }
        pumpRepo(repo.id)
        let after = try db.read { try Dispatch.fetchOne($0, key: d.id) }
        if after?.state == .delivered { return .delivered(seq: d.seq) }
        if let after, after.state == .queued, after.attempts > 0 {
            return .deliveryFailed(seq: d.seq, attempts: after.attempts)
        }
        let pane = lookups.repoPane(repo.id)
        // 안 뜬 페인은 "안 떠 있다" 가 먼저다 — 한도가 풀려도 사람이 시작해야 간다.
        if pane.started, let until = pane.limitedUntil { return .queuedLimited(seq: d.seq, until: until) }
        return pane.started ? .queuedBusy(seq: d.seq) : .queuedNotStarted(seq: d.seq)
    }

    /// 조율자의 답(이슈 #43). 그 레포의 미답 질문이 없으면 아무것도 쓰지 않는다 — 답이 "큐를 건너뛰는 배분" 이 되면 안 된다.
    /// 그때 아직 안 간 답이 큐에 있으면 `answerPending` — `noQuestion` 의 "dispatch 를 쓴다" 로 몰지 않는다(최종 리뷰 2).
    /// 질문이 나온 배분이 이미 닫혔으면 펌프 전에 그 자리에서 실패로 닫고 `dispatchClosed` 로만 알린다 — 툴 오류가 곧 보고라
    /// relay 를 또 쓰면 조율자가 같은 실패를 두 번 듣는다(최종 리뷰 1). 닫힌 배분은 다시 열리지 않으므로 펌프해도 같은 결과다.
    /// 나머지 결과는 `enqueue` 와 같은 결로 흘린 뒤의 답 상태에서 정한다.
    func answer(workspaceID: String, repo: Repo, body: String) throws -> AnswerOutcome {
        let created = try db.write { db -> Answer? in
            try DispatchOps.enqueueAnswer(workspaceID: workspaceID, repoID: repo.id, body: body, now: now(), in: db)
        }
        guard let a = created else {
            let pending = try db.read { try !DispatchOps.queuedAnswers(repoID: repo.id, in: $0).isEmpty }
            return pending ? .answerPending : .noQuestion
        }
        if let closed = try closedDispatch(boundTo: a) {
            try db.write { try DispatchOps.markAnswerFailed(a.id, reason: Self.answerDispatchClosed, in: $0) }
            return .dispatchClosed(seq: closed.seq)
        }
        pumpRepo(repo.id)
        let after = try db.read { try Answer.fetchOne($0, key: a.id) }
        if after?.state == .delivered { return .delivered }
        if let after, after.attempts > 0 { return .deliveryFailed(attempts: after.attempts) }
        let pane = lookups.repoPane(repo.id)
        if pane.started, let until = pane.limitedUntil { return .queuedLimited(until: until) }
        return pane.started ? .queuedBusy : .queuedNotStarted
    }

    func relay(workspaceID: String, dispatchID: String?, repoID: String?, kind: RelayKind, body: String) throws {
        _ = try db.write {
            try DispatchOps.enqueueRelay(workspaceID: workspaceID, dispatchID: dispatchID, repoID: repoID,
                                         kind: kind, body: body, now: now(), in: $0)
        }
        pumpOrchestrator(workspaceID)
    }

    // MARK: - 훅

    /// 레포 페인의 새 세션. 열린 배분이 있으면 `DispatchRules.onSessionStart` 로 이어받기 · 유지 · 실패를 정한다(이슈 #24).
    func didStart(repoID: String, session: String?, source: String) {
        let open: Dispatch?
        do { open = try db.read { try DispatchOps.outstanding(repoID: repoID, in: $0) } } catch {
            NSLog("[Dure] 배분 세션 처리 실패: \(error)"); open = nil
        }
        // compact 는 같은 턴 한가운데서도 일어난다 — 그때는 Stop 이 아직 온다. 그 밖의 시작은 옛 턴의 Stop 이 오지 않는다.
        // 단 Codex 는 SessionStart 가 스레드의 **첫 턴** 직전에 뜬다(h-queued-turn-hooks) — 방금 그 스레드에 넣은 배분이
        // 그 첫 턴이면 같은 턴이 아직 돌고 Stop 도 온다. 그때 풀면 그 턴 중에 다음 배분이 들어가 앞 턴의 Stop 이 그것을
        // waiting 으로 만든다(최종 리뷰 I1). Claude 의 startup 은 늘 새 세션 id 라 여기 걸리지 않는다.
        let firstTurnOfQueued = session != nil && open?.deliveredSession == session && source == "startup"
        if source != "compact" && !firstTurnOfQueued { repoAwaitingStop.remove(repoID) }
        do {
            if let open, let session {
                switch DispatchRules.onSessionStart(deliveredSession: open.deliveredSession, newSession: session, source: source) {
                case .adopt:
                    try db.write { try DispatchOps.adoptSession(open.id, session: session, in: $0) }
                case .keep:
                    break
                case .fail:
                    try db.write { try DispatchOps.markFailed(open.id, reason: "세션 재시작", now: now(), in: $0) }
                    try relay(workspaceID: open.workspaceId, dispatchID: open.id, repoID: repoID, kind: .failure,
                              body: "그 페인의 세션이 새로 시작됐다(/clear 또는 재시작). 배분의 대화가 끊겨 완료를 받을 수 없다. 사람에게 확인하라.")
                }
            }
        } catch { NSLog("[Dure] 배분 세션 처리 실패: \(error)") }
        pumpRepo(repoID)
    }

    /// 턴이 끝났다. 열린 배분이 있으면 **완료가 아니라 응답 대기**다 — 에이전트가 사람에게 묻고 멈췄을 수 있다(이슈 #24).
    /// 조율자에게 "끝남" 을 보내지 않고, 그 페인에 다음 배분을 넣지 않는다. 마지막 답은 남겨 둔다.
    /// 배분이 아닌 턴(사람이 직접 친 것)이나 이미 `complete` 한 배분의 Stop 은 큐만 흘린다.
    func didStop(repoID: String, lastMessage: String?) {
        repoAwaitingStop.remove(repoID)   // 먼저 푼다 — 아래 pump 가 다음 배분을 넣을 수 있어야 한다
        // 한도로 끊긴 턴에는 Stop 이 없다 — 한도 뒤 Stop 은 실제로 돈 턴(사람이 이어 갔거나 이어 하기 턴)이라 이어 하기를 보내지 않는다.
        limitInterrupted.removeValue(forKey: repoID)
        do {
            if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) {
                try db.write { try DispatchOps.markWaiting(open.id, lastMessage: lastMessage, in: $0) }
            }
        } catch { NSLog("[Dure] 배분 응답 대기 기록 실패: \(error)") }
        pumpRepo(repoID)
    }

    /// 레포 에이전트의 `complete`. 하던 배분을 닫고 요약을 조율자에게 올린다. 열린 배분이 없으면 nil.
    /// 다음 배분은 이 턴의 Stop 뒤에 흐른다 — 지금은 그 페인이 아직 이 턴을 돌고 있다.
    func complete(repoID: String, summary: String, completion: DispatchCompletion = .init()) throws -> Int? {
        guard let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) else { return nil }
        try db.write { try DispatchOps.markDone(open.id, result: summary, completion: completion, now: now(), in: $0) }
        let body = DispatchGit.completionNote(open, completion).map { $0 + "\n" + summary } ?? summary
        try relay(workspaceID: open.workspaceId, dispatchID: open.id, repoID: repoID, kind: .completion, body: body)
        pumpRepo(repoID)
        return open.seq
    }

    /// 대시보드 ④ [완료로 닫기] — 에이전트가 `complete` 를 잊었을 때. 마지막 답을 결과로 조율자에게 올린다.
    /// 이 워크스페이스의 열린 배분만 닫는다.
    func closeByHuman(_ id: String, workspaceID: String) throws -> Bool {
        guard let open = try db.read({ try Dispatch.filter(Column("id") == id && Column("workspace_id") == workspaceID
                                                           && DispatchOps.openStates.contains(Column("state"))).fetchOne($0) })
        else { return false }
        let result = open.result ?? "(요약 없음 — 사람이 완료로 닫았다)"
        try db.write { try DispatchOps.markDone(open.id, result: result, now: now(), in: $0) }
        try relay(workspaceID: workspaceID, dispatchID: open.id, repoID: open.repoId, kind: .completion, body: result)
        pumpRepo(open.repoId)
        return true
    }

    func didStopOrchestrator(workspaceID: String) {
        orchestratorAwaitingStop.remove(workspaceID)
        lastOrchestratorBundle.removeValue(forKey: workspaceID)   // 그 턴이 묶음을 읽고 끝났다
        pumpOrchestrator(workspaceID)
    }

    /// 새 조율자 세션(`SessionStart`). 기동 프롬프트로 실은 묶음은 이 세션이 첫 턴으로 읽으니 Stop 을 기다릴 게
    /// 아니지만, **옛 세션에 걸어 둔 표식**이 남아 있으면 영영 아무것도 안 간다 — 지우고 흘린다.
    func didStartOrchestrator(workspaceID: String) {
        orchestratorAwaitingStop.remove(workspaceID)
        pumpOrchestrator(workspaceID)
    }

    /// 조율자 페인이 죽었다. 그 세션의 Stop 은 오지 않는다.
    func didDieOrchestrator(workspaceID: String) {
        orchestratorAwaitingStop.remove(workspaceID)
        lastOrchestratorBundle.removeValue(forKey: workspaceID)
    }

    func didDie(repoID: String) {
        repoAwaitingStop.remove(repoID)   // 죽은 세션의 Stop 은 오지 않는다
        do {
            guard let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) else { return }
            try db.write { try DispatchOps.markFailed(open.id, reason: "페인 종료", now: now(), in: $0) }
            try relay(workspaceID: open.workspaceId, dispatchID: open.id, repoID: repoID,
                      kind: .failure, body: "페인이 종료됐다. 다시 시작하면 큐의 다음 것부터 간다.")
        } catch { NSLog("[Dure] 배분 실패 기록 실패: \(error)") }
    }

    /// 앱 시작 때. `delivered` 로 남은 것은 Stop 을 영영 못 본다.
    func recoverOnLaunch() {
        do {
            let closed = try db.write { try DispatchOps.failUndelivered(reason: "앱 종료", now: now(), in: $0) }
            for d in closed {
                try relay(workspaceID: d.workspaceId, dispatchID: d.id, repoID: d.repoId, kind: .failure,
                          body: "앱이 종료되는 사이 전달됐던 배분이라 결과를 못 받았다. 페인에서 직접 확인하라.")
            }
        } catch { NSLog("[Dure] 배분 복구 실패: \(error)") }
    }

    /// 앱 주기 틱(30초)에서 부른다. 소켓 실패는 훅이 다시 오지 않으므로 여기서만 재시도된다.
    /// 시도한 적이 있는(`attempts > 0`) 레포만 민다 — 나머지는 훅이 알아서 흘린다.
    func retryPending() {
        pumpQueued(retriedOnly: true)
    }

    /// 큐에 뭔가 있는 레포 · 워크스페이스를 민다. `retriedOnly` 면 레포는 시도한 적이 있는 것만.
    private func pumpQueued(retriedOnly: Bool) {
        do {
            let (repos, workspaces) = try db.read { db -> (Set<String>, Set<String>) in
                var dq = Column("state") == DispatchState.queued.rawValue
                var aq = Column("state") == AnswerState.queued.rawValue
                if retriedOnly { dq = dq && Column("attempts") > 0; aq = aq && Column("attempts") > 0 }
                let d = try Dispatch.filter(dq).fetchAll(db)
                let a = try Answer.filter(aq).fetchAll(db)
                let r = try Relay.filter(Column("state") == RelayState.queued.rawValue).fetchAll(db)
                return (Set(d.map(\.repoId) + a.map(\.repoId)), Set(r.map(\.workspaceId)))
            }
            for id in repos.sorted() { pumpRepo(id) }
            for id in workspaces.sorted() { pumpOrchestrator(id) }
        } catch { NSLog("[Dure] 배분 큐 흘리기 실패: \(error)") }
    }

    // MARK: - Codex 계정 한도 (4단계, D-46)

    /// 재시도 없는 `usageLimitExceeded` 가 그 페인(레포 페인이면 `repoID`, 조율자면 nil)의 턴을 끊었다. 그 턴에는 Stop 이 없다.
    /// - 레포 페인: 일하는 중(`delivered`)인 배분이 있으면 닫지 않고 기억한다(풀리면 이어 하기). `repoAwaitingStop` 은 그대로 —
    ///   이어 하기 턴의 Stop 이 푼다. 응답 대기(`waiting`)면 끊긴 턴은 사람이 친 것이라 이어 하지 않는다. 기억할 것이 없으면
    ///   Stop 대기를 푼다(배분 밖 답의 턴이 끊겼으면 영영 막힌다).
    /// - 조율자: 그 턴에 넘긴 묶음은 읽히지 않았다 — 다시 큐로 돌리고 Stop 대기를 푼다(풀린 뒤 펌프로 다시 간다).
    /// 조율자에게는 막힘마다 워크스페이스당 한 번만 알린다. 조율자도 막혀 있으면 그 안내도 큐에 남는다.
    /// `announce == false` 면(풀린 직후 다시 막힘 — `CodexLimitState.quietAfterRelease`) 막기만 하고 알리지 않는다.
    func didHitUsageLimit(repoID: String?, workspaceID: String, until: Int, announce: Bool = true) {
        do {
            var dispatchID: String?
            if let repoID {
                if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }), open.state == .delivered {
                    limitInterrupted[repoID] = open.id
                    dispatchID = open.id
                } else {
                    repoAwaitingStop.remove(repoID)
                }
            } else {
                if let ids = lastOrchestratorBundle.removeValue(forKey: workspaceID) {
                    try db.write { try DispatchOps.requeueRelays(ids, in: $0) }
                    resentRelays.formUnion(ids)
                }
                orchestratorAwaitingStop.remove(workspaceID)
            }
            guard announce, limitNoticed.insert(workspaceID).inserted else { return }
            try relay(workspaceID: workspaceID, dispatchID: dispatchID, repoID: repoID, kind: .limit,
                      body: DispatchBody.limitNotice(until: until))
        } catch { NSLog("[Dure] Codex 한도 처리 실패: \(error)") }
    }

    /// 한도가 풀렸다(`read` 값으로 판정 — 스토어가 `limitedUntil` 을 먼저 비운다). 끊긴 배분이 아직 열려 있으면 그 페인에
    /// 이어 하기를 한 번 보내고, 알렸던 워크스페이스에 풀림을 알린 뒤 큐를 전부 흘린다. 두 번 불려도 이어 하기는 한 번이다.
    func didReleaseUsageLimit() {
        let interrupted = limitInterrupted
        limitInterrupted = [:]
        let workspaces = limitNoticed   // 알린 곳에만 풀림을 알린다
        limitNoticed = []
        for (repoID, id) in interrupted.sorted(by: { $0.key < $1.key }) {
            do {
                guard let d = try db.read({ try Dispatch.fetchOne($0, key: id) }),
                      DispatchOps.openStates.contains(d.state.rawValue) else {
                    repoAwaitingStop.remove(repoID)   // 그 사이 닫혔다 — 끊긴 턴의 Stop 은 오지 않는다
                    continue
                }
                try resumeAfterLimit(d, repoID: repoID)
            } catch { NSLog("[Dure] 한도 뒤 이어 하기 실패: \(error)") }
        }
        for ws in workspaces.sorted() {
            do {
                try relay(workspaceID: ws, dispatchID: nil, repoID: nil, kind: .limit, body: DispatchBody.limitReleased)
            } catch { NSLog("[Dure] 한도 풀림 안내 실패: \(error)") }
        }
        pumpQueued(retriedOnly: false)
    }

    private func resumeAfterLimit(_ d: Dispatch, repoID: String) throws {
        let pane = lookups.repoPane(repoID)
        if pane.limitedUntil != nil {   // 아직 막힌 페인이면 다음 풀림까지 둔다
            limitInterrupted[repoID] = d.id
            return
        }
        // 사람이 이미 그 페인에서 턴을 돌리고 있다 — 끼어들지 않는다. 그 턴의 Stop 이 Stop 대기를 풀고 보통 흐름으로 간다.
        if pane.state == .running { return }
        // 그 사이 새 스레드를 열었으면(`/new`) 그 스레드는 배분의 맥락이 없다 — 새 스레드의 SessionStart 가 배분을 닫는다.
        if case .codex? = pane.address, let delivered = d.deliveredSession, delivered != "argv",
           delivered != pane.address?.sessionKey {
            repoAwaitingStop.remove(repoID)
            return
        }
        guard let address = pane.address else {
            repoAwaitingStop.remove(repoID)
            try relay(workspaceID: d.workspaceId, dispatchID: d.id, repoID: repoID, kind: .limit,
                      body: Self.resumeNotSent(d.seq))
            return
        }
        do {
            try messaging.send(DispatchBody.resumeAfterLimit(d, repoName: lookups.repoName(repoID), kind: pane.kind), to: address)
        } catch {
            NSLog("[Dure] 배분 #\(d.seq) 이어 하기 전달 실패: \(error)")
            repoAwaitingStop.remove(repoID)
            try relay(workspaceID: d.workspaceId, dispatchID: d.id, repoID: repoID, kind: .limit,
                      body: Self.resumeNotSent(d.seq))
            return
        }
        repoAwaitingStop.insert(repoID)
        // 끊긴 뒤 사람이 친 턴이 Stop 으로 응답 대기를 만들었을 수 있다 — 다시 일하는 중으로.
        do { try db.write { try DispatchOps.reopen(d.id, in: $0) } } catch {
            NSLog("[Dure] 배분 #\(d.seq) 이어 하기 보냈지만 기록 실패: \(error)")
        }
    }

    static func resumeNotSent(_ seq: Int) -> String {
        "배분 #\(seq) 을 이어 하라고 그 페인에 보내지 못했다. 배분은 열려 있다 — 사람에게 그 페인에서 이어 가게 하라고 알린다."
    }

    // MARK: - 흐름

    /// 답(이슈 #43)이 배분보다 먼저다. 큐에 답이 있으면 그것만 다루고 돌아간다 — 지금 못 보내면 배분도 보내지 않는다.
    func pumpRepo(_ repoID: String) {
        do {
            let pane = lookups.repoPane(repoID)
            let open = try db.read { try DispatchOps.outstanding(repoID: repoID, in: $0) }
            if let next = try db.read({ try DispatchOps.queuedAnswers(repoID: repoID, in: $0) }).first {
                try pumpAnswer(next, repoID: repoID, pane: pane, open: open)
                return
            }
            guard pane.limitedUntil == nil, !repoAwaitingStop.contains(repoID),
                  DispatchRules.isIdle(started: pane.started, state: pane.state, hasOutstanding: open != nil),
                  let address = pane.address,
                  let next = try db.read({ try DispatchOps.queued(repoID: repoID, in: $0) }).first else { return }
            let body = DispatchBody.dispatch(next, repoName: lookups.repoName(repoID), kind: pane.kind)
            do {
                try messaging.send(body, to: address)
            } catch {
                let n = try db.write { try DispatchOps.bumpAttempts(next.id, in: $0) }
                NSLog("[Dure] 배분 #\(next.seq) 전달 실패 \(n)회: \(error)")
                if DispatchRules.givesUp(afterAttempts: n) {
                    try db.write { try DispatchOps.markFailed(next.id, reason: "전달 실패 \(n)회", now: now(), in: $0) }
                    try relay(workspaceID: next.workspaceId, dispatchID: next.id, repoID: repoID, kind: .failure,
                              body: Self.deliveryFailure(n, kind: pane.kind))
                    pumpRepo(repoID)   // 다음 것을 시도한다
                }
                return
            }
            repoAwaitingStop.insert(repoID)
            // 보낸 뒤의 기록 실패는 "안 보냄" 이 아니다 — 재시도로 몰면 같은 지시가 두 번 간다. 로그만 남긴다.
            // 세션 열쇠(Claude 세션 · Codex 스레드)를 적는다 — 다음 `SessionStart` 의 `session_id` 와 견준다.
            do {
                try db.write { try DispatchOps.markDelivered(next.id, session: address.sessionKey, now: now(), in: $0) }
            } catch { NSLog("[Dure] 배분 #\(next.seq) 보냈지만 기록 실패: \(error)") }
        } catch { NSLog("[Dure] 배분 전달 실패: \(error)") }
    }

    /// `answer.failure` — 질문이 나온 배분이 보내기 전에 닫혔다.
    static let answerDispatchClosed = "배분이 닫힘"

    /// 전달을 포기했을 때 조율자에게 가는 글. Claude 는 인박스 소켓, Codex 는 `codex queue` 라 "소켓" 은 Claude 에만 맞다.
    static func deliveryFailure(_ n: Int, kind: AgentKind) -> String {
        switch kind {
        case .claude: "소켓에 \(n)번 쓰지 못했다. 페인이 메시지를 받는 상태인지 확인하라."
        case .codex: "전달에 \(n)번 실패했다. 페인이 메시지를 받는 상태인지 확인하라."
        }
    }

    static func answerDeliveryFailure(_ n: Int, kind: AgentKind) -> String {
        switch kind {
        case .claude: "조율자 답을 소켓에 \(n)번 쓰지 못했다. 페인이 메시지를 받는 상태인지 확인하라."
        case .codex: "조율자 답 전달에 \(n)번 실패했다. 페인이 메시지를 받는 상태인지 확인하라."
        }
    }

    /// 답이 묶인 배분이 이미 닫혔으면 그 배분. 배분 밖 답(nil)이나 열린 배분이면 nil.
    private func closedDispatch(boundTo a: Answer) throws -> Dispatch? {
        guard let id = a.dispatchId, let d = try db.read({ try Dispatch.fetchOne($0, key: id) }),
              !DispatchOps.openStates.contains(d.state.rawValue) else { return nil }
        return d
    }

    /// 큐 맨 앞의 답 하나(설계 3절). 실패로 닫으면 `pumpRepo` 를 다시 불러 다음 답이나 배분으로 넘어간다.
    /// 보내면 한 턴에 하나 — `repoAwaitingStop` 에 넣고, 묶인 배분이 응답 대기면 다시 일하는 중(`delivered`)으로 되돌린다.
    private func pumpAnswer(_ a: Answer, repoID: String, pane: PaneView, open: Dispatch?) throws {
        // 답은 질문이 나온 배분에 묶여 있다. 그 배분이 닫혔으면 지금 열린 다른 배분에 붙이지 않는다(검토 1).
        // 여기 오는 답은 큐에서 기다리던 것이다 — 툴 응답이 이미 나갔으니 relay 로 알린다(그 자리 실패는 `answer` 가 거른다).
        if let closed = try closedDispatch(boundTo: a) {
            try db.write { try DispatchOps.markAnswerFailed(a.id, reason: Self.answerDispatchClosed, in: $0) }
            try relay(workspaceID: a.workspaceId, dispatchID: closed.id, repoID: repoID, kind: .answerFailure,
                      body: "배분 #\(closed.seq) 이 이미 닫혀 답을 전하지 못했다. 사람에게 알린다. 사람이 '진행' 하면 질문과 답을 instruction 에 넣어 다시 dispatch 한다(원래 배분 종류대로).")
            pumpRepo(repoID)
            return
        }
        let bound = try a.dispatchId.flatMap { id in try db.read { try Dispatch.fetchOne($0, key: id) } }
        // 열린 배분이 `delivered` 면 그 턴(argv 첫 턴 포함)이 아직 돈다 — `canAnswer` 가 막는다(검토 2).
        guard pane.limitedUntil == nil, !repoAwaitingStop.contains(repoID),
              DispatchRules.canAnswer(started: pane.started, state: pane.state, open: open?.state),
              let address = pane.address else { return }
        // Codex `/new` 는 새 스레드를 열어도 SessionStart 가 그 스레드의 첫 턴까지 미뤄진다 — 그 사이 주소는 새 스레드인데
        // 열린 배분은 옛 스레드에 있다. 답을 지금 주소로 보내면 질문의 맥락이 없는 스레드가 받는다(최종 리뷰 I2).
        // 큐에 둔다 — 새 스레드의 SessionStart 가 배분을 닫으면 위 `closedDispatch` 가 실패로 알린다.
        // Claude 는 `/clear` · 재시작의 SessionStart 가 곧바로 배분을 닫아 이 경우가 없다 — 동작을 바꾸지 않게 Codex 주소로만 거른다.
        // argv 로 실은 배분은 아직 스레드를 모른다(첫 SessionStart 가 이어받는다) — 막지 않는다.
        if case .codex = address, let delivered = open?.deliveredSession, delivered != "argv",
           delivered != address.sessionKey { return }
        let question = try a.questionId.flatMap { id in try db.read { try Relay.fetchOne($0, key: id)?.body } }
        let body = DispatchBody.answer(seq: bound?.seq, question: question, body: a.body)
        do {
            try messaging.send(body, to: address)
        } catch {
            let n = try db.write { try DispatchOps.bumpAnswerAttempts(a.id, in: $0) }
            NSLog("[Dure] 조율자 답 전달 실패 \(n)회: \(error)")
            if DispatchRules.givesUp(afterAttempts: n) {
                try db.write { try DispatchOps.markAnswerFailed(a.id, reason: "전달 실패 \(n)회", in: $0) }
                try relay(workspaceID: a.workspaceId, dispatchID: a.dispatchId, repoID: repoID, kind: .answerFailure,
                          body: Self.answerDeliveryFailure(n, kind: pane.kind))
                pumpRepo(repoID)   // 다음 것을 시도한다
            }
            return
        }
        repoAwaitingStop.insert(repoID)
        // 보낸 뒤의 기록 실패는 "안 보냄" 이 아니다 — 같은 답이 두 번 가지 않게 로그만 남긴다.
        do {
            try db.write { db in
                try DispatchOps.markAnswerDelivered(a.id, now: now(), in: db)
                if let bound { try DispatchOps.reopen(bound.id, in: db) }
            }
        } catch { NSLog("[Dure] 조율자 답 보냈지만 기록 실패: \(error)") }
    }

    func pumpOrchestrator(_ workspaceID: String) {
        do {
            let pane = lookups.orchestratorPane(workspaceID)
            guard pane.limitedUntil == nil,
                  DispatchRules.isIdle(started: pane.started, state: pane.state,
                                       hasOutstanding: orchestratorAwaitingStop.contains(workspaceID)),
                  let address = pane.address else { return }
            let queued = try db.read { try DispatchOps.queuedRelays(workspaceID: workspaceID, in: $0) }
            guard !queued.isEmpty else { return }
            try messaging.send(try bundleBody(queued), to: address)
            // 보냈으면 그 턴이 끝날 때까지 다음 묶음은 쌓아 둔다(아래 기록이 실패해도 보낸 것은 보낸 것이다).
            orchestratorAwaitingStop.insert(workspaceID)
            lastOrchestratorBundle[workspaceID] = queued.map(\.id)
            resentRelays.subtract(queued.map(\.id))
            try db.write { try DispatchOps.markRelaysDelivered(queued.map(\.id), now: now(), in: $0) }
        } catch { NSLog("[Dure] 조율자행 전달 실패: \(error)") }
    }

    // MARK: - 기동 프롬프트

    /// 배분만 싣는다. 조율자 답은 싣지 않는다 — 새 세션은 질문의 맥락이 없다(설계 3절). 답은 `SessionStart` 뒤 `pumpRepo` 로 간다.
    func initialPrompt(forRepo repoID: String) -> String? {
        do {
            let pane = lookups.repoPane(repoID)
            let kind = pane.kind
            // 뷰가 다시 그려지며 두 번 불릴 수 있다. 이미 argv 로 실은 것이 열려 있으면 같은 것을 다시 준다 —
            // 다음 것을 꺼내면 보내지도 않은 배분이 `delivered` 가 된다. 소켓으로 간 것이 열려 있으면 실을 것이 없다.
            if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) {
                guard open.deliveredSession == "argv" else { return nil }
                return DispatchBody.dispatch(open, repoName: lookups.repoName(repoID), kind: kind)
            }
            // Codex 한도로 막혀 있으면 싣지 않는다 — 그 첫 턴도 한도로 실패한다. 풀리면 `pumpRepo` 가 보낸다.
            guard pane.limitedUntil == nil,
                  let next = try db.read({ try DispatchOps.queued(repoID: repoID, in: $0) }).first else { return nil }
            try db.write { try DispatchOps.markDelivered(next.id, session: "argv", now: now(), in: $0) }
            return DispatchBody.dispatch(next, repoName: lookups.repoName(repoID), kind: kind)
        } catch { NSLog("[Dure] 기동 프롬프트 실패: \(error)"); return nil }
    }

    func initialPrompt(forOrchestrator workspaceID: String) -> String? {
        do {
            guard lookups.orchestratorPane(workspaceID).limitedUntil == nil else { return nil }
            let queued = try db.read { try DispatchOps.queuedRelays(workspaceID: workspaceID, in: $0) }
            guard !queued.isEmpty else { return nil }
            // 먼저 만든다 — 렌더가 실패했는데 전달로 찍히면 묶음이 사라진다.
            let bundle = try bundleBody(queued)
            try db.write { try DispatchOps.markRelaysDelivered(queued.map(\.id), now: now(), in: $0) }
            resentRelays.subtract(queued.map(\.id))
            // 첫 프롬프트도 한 턴이다 — 그 Stop 전에 소켓으로 다음 것을 넣지 않는다. 단 곧 올 `SessionStart` 가
            // 지운다(`didStartOrchestrator`) — `/clear` 처럼 Stop 없이 세션이 바뀌는 길에서 표식이 박히지 않게 하는
            // 쪽을 골랐다. 그래서 SessionStart 와 첫 `UserPromptSubmit` 사이 짧은 틈에 온 relay 는 바로 갈 수 있다.
            orchestratorAwaitingStop.insert(workspaceID)
            lastOrchestratorBundle[workspaceID] = queued.map(\.id)
            return bundle
        } catch { NSLog("[Dure] 조율자 기동 프롬프트 실패: \(error)"); return nil }
    }

    /// 묶음 글. 한도로 끊긴 턴에서 되돌린 relay 가 섞였으면 앞에 "다시 보낸다" 한 줄.
    private func bundleBody(_ queued: [Relay]) throws -> String {
        let body = DispatchBody.bundle(try queued.map(render))
        return queued.contains(where: { resentRelays.contains($0.id) }) ? DispatchBody.limitResent + "\n\n" + body : body
    }

    private func render(_ r: Relay) throws -> String {
        let seq = try r.dispatchId.flatMap { id in try db.read { try Dispatch.fetchOne($0, key: id)?.seq } }
        return DispatchBody.relay(r.kind, seq: seq, repoName: r.repoId.map(lookups.repoName) ?? "?",
                                  body: r.body, time: DispatchRules.clock(r.createdAt))
    }

    // MARK: - 조회 · 취소

    func cancel(_ ref: DispatchRules.CancelRef, workspaceID: String) throws -> Bool {
        try db.write { db in
            let id: String?
            switch ref {
            case .id(let s):
                // 번호처럼 id 도 이 워크스페이스 안에서만 찾는다 — 다른 워크스페이스 배분을 취소하면 안 된다.
                id = try Dispatch.filter(Column("id") == s && Column("workspace_id") == workspaceID).fetchOne(db)?.id
            case .seq(let n):
                id = try Dispatch.filter(Column("workspace_id") == workspaceID && Column("seq") == n).fetchOne(db)?.id
            }
            guard let id else { return false }
            return try DispatchOps.cancel(id, in: db)
        }
    }

    /// 이 레포가 하고 있는 배분(전달됨 · 응답 대기). 레포의 `report` · `ask_orchestrator` 가 어느 배분 얘기인지 붙인다.
    func outstandingDispatchID(repoID: String) -> String? {
        (try? db.read { try DispatchOps.outstanding(repoID: repoID, in: $0) })?.id
    }

    func queueCount(repoID: String) -> Int {
        (try? db.read { try DispatchOps.queued(repoID: repoID, in: $0).count }) ?? 0
    }

    func history(workspaceID: String) -> [Dispatch] {
        (try? db.read { try DispatchOps.history(workspaceID: workspaceID, in: $0) }) ?? []
    }

    func relays(workspaceID: String) -> [Relay] {
        (try? db.read { try DispatchOps.relays(workspaceID: workspaceID, in: $0) }) ?? []
    }

    func answers(workspaceID: String) -> [Answer] {
        (try? db.read { try DispatchOps.answers(workspaceID: workspaceID, in: $0) }) ?? []
    }
}
