import Foundation
import GRDB

/// 단계 4 — 배분의 흐름을 맡는 유일한 곳. 설계 3절.
///
/// 들어오는 것: 조율자의 `dispatch`(enqueue) · 레포의 `complete`/`report`/`ask`(complete · relay) · 사람의 [완료로 닫기](closeByHuman)
/// · 훅(didStart · didStop · didDie) · 앱 시작(recover).
/// **완료는 레포 에이전트가 `complete` 로 선언한다**(이슈 #24). 턴이 끝난 것(Stop)은 완료가 아니다 — 사람에게 묻고 멈췄을 수 있다.
/// 나가는 것: 인박스 소켓(`InboxSending`) 또는 기동 프롬프트(`initialPrompt`). 판단은 `DispatchRules`, 행은 `DispatchOps`.
///
/// 스토어의 상태는 `Lookups` 클로저로 받는다 — 스토어는 실제 DB 를 쓰므로 여기서 직접 잡으면 테스트가 안 된다.
@MainActor
final class Dispatcher {

    struct PaneView {
        var started: Bool
        var state: AgentState?
        /// 현재 cc_session_id. 레지스트리에서 소켓을 찾는 열쇠.
        var claudeSessionID: String?
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
    }

    private let db: DatabaseQueue
    private let inbox: InboxSending
    let lookups: Lookups
    private let now: () -> Int
    /// 조율자에게 묶음을 넣고 그 턴의 `Stop` 을 아직 못 본 워크스페이스. 레포의 `outstanding` 과 같은 가드다 —
    /// 소켓이 시작한 턴에 `UserPromptSubmit` 이 뜨는지 미확인이라 상태(`done`)만 믿으면 조율자가 첫 묶음을
    /// 읽는 중에 다음 묶음이 끼어든다. 메모리에만 둔다 — 앱을 다시 켜면 조율자 세션도 새로 뜬다.
    private var orchestratorAwaitingStop: Set<String> = []

    init(db: DatabaseQueue, inbox: InboxSending, lookups: Lookups,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.db = db; self.inbox = inbox; self.lookups = lookups; self.now = now
    }

    // MARK: - 들어오는 것

    func enqueue(workspaceID: String, repo: Repo, title: String?, instruction: String,
                 toolUseId: String?) throws -> EnqueueOutcome {
        let d = try db.write {
            try DispatchOps.enqueue(workspaceID: workspaceID, repoID: repo.id, title: title,
                                    instruction: instruction, toolUseId: toolUseId, now: now(), in: $0)
        }
        pumpRepo(repo.id)
        let after = try db.read { try Dispatch.fetchOne($0, key: d.id) }
        if after?.state == .delivered { return .delivered(seq: d.seq) }
        if let after, after.state == .queued, after.attempts > 0 {
            return .deliveryFailed(seq: d.seq, attempts: after.attempts)
        }
        return lookups.repoPane(repo.id).started ? .queuedBusy(seq: d.seq) : .queuedNotStarted(seq: d.seq)
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
        do {
            if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }), let session {
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
        do {
            if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) {
                try db.write { try DispatchOps.markWaiting(open.id, lastMessage: lastMessage, in: $0) }
            }
        } catch { NSLog("[Dure] 배분 응답 대기 기록 실패: \(error)") }
        pumpRepo(repoID)
    }

    /// 레포 에이전트의 `complete`. 하던 배분을 닫고 요약을 조율자에게 올린다. 열린 배분이 없으면 nil.
    /// 다음 배분은 이 턴의 Stop 뒤에 흐른다 — 지금은 그 페인이 아직 이 턴을 돌고 있다.
    func complete(repoID: String, summary: String) throws -> Int? {
        guard let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) else { return nil }
        try db.write { try DispatchOps.markDone(open.id, result: summary, now: now(), in: $0) }
        try relay(workspaceID: open.workspaceId, dispatchID: open.id, repoID: repoID, kind: .completion, body: summary)
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
    }

    func didDie(repoID: String) {
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
        do {
            let (repos, workspaces) = try db.read { db -> (Set<String>, Set<String>) in
                let d = try Dispatch.filter(Column("state") == DispatchState.queued.rawValue && Column("attempts") > 0)
                    .fetchAll(db)
                let r = try Relay.filter(Column("state") == RelayState.queued.rawValue).fetchAll(db)
                return (Set(d.map(\.repoId)), Set(r.map(\.workspaceId)))
            }
            for id in repos.sorted() { pumpRepo(id) }
            for id in workspaces.sorted() { pumpOrchestrator(id) }
        } catch { NSLog("[Dure] 배분 재시도 실패: \(error)") }
    }

    // MARK: - 흐름

    func pumpRepo(_ repoID: String) {
        do {
            let pane = lookups.repoPane(repoID)
            let open = try db.read { try DispatchOps.outstanding(repoID: repoID, in: $0) }
            guard DispatchRules.isIdle(started: pane.started, state: pane.state, hasOutstanding: open != nil),
                  let session = pane.claudeSessionID,
                  let next = try db.read({ try DispatchOps.queued(repoID: repoID, in: $0) }).first else { return }
            let body = DispatchBody.dispatch(seq: next.seq, repoName: lookups.repoName(repoID), instruction: next.instruction)
            do {
                try inbox.send(body, toClaudeSession: session)
            } catch {
                let n = try db.write { try DispatchOps.bumpAttempts(next.id, in: $0) }
                NSLog("[Dure] 배분 #\(next.seq) 전달 실패 \(n)회: \(error)")
                if DispatchRules.givesUp(afterAttempts: n) {
                    try db.write { try DispatchOps.markFailed(next.id, reason: "전달 실패 \(n)회", now: now(), in: $0) }
                    try relay(workspaceID: next.workspaceId, dispatchID: next.id, repoID: repoID, kind: .failure,
                              body: "소켓에 \(n)번 쓰지 못했다. 페인이 메시지를 받는 상태인지 확인하라.")
                    pumpRepo(repoID)   // 다음 것을 시도한다
                }
                return
            }
            // 보낸 뒤의 기록 실패는 "안 보냄" 이 아니다 — 재시도로 몰면 같은 지시가 두 번 간다. 로그만 남긴다.
            do {
                try db.write { try DispatchOps.markDelivered(next.id, session: session, now: now(), in: $0) }
            } catch { NSLog("[Dure] 배분 #\(next.seq) 보냈지만 기록 실패: \(error)") }
        } catch { NSLog("[Dure] 배분 전달 실패: \(error)") }
    }

    func pumpOrchestrator(_ workspaceID: String) {
        do {
            let pane = lookups.orchestratorPane(workspaceID)
            guard DispatchRules.isIdle(started: pane.started, state: pane.state,
                                       hasOutstanding: orchestratorAwaitingStop.contains(workspaceID)),
                  let session = pane.claudeSessionID else { return }
            let queued = try db.read { try DispatchOps.queuedRelays(workspaceID: workspaceID, in: $0) }
            guard !queued.isEmpty else { return }
            try inbox.send(DispatchBody.bundle(try queued.map(render)), toClaudeSession: session)
            // 보냈으면 그 턴이 끝날 때까지 다음 묶음은 쌓아 둔다(아래 기록이 실패해도 보낸 것은 보낸 것이다).
            orchestratorAwaitingStop.insert(workspaceID)
            try db.write { try DispatchOps.markRelaysDelivered(queued.map(\.id), now: now(), in: $0) }
        } catch { NSLog("[Dure] 조율자행 전달 실패: \(error)") }
    }

    // MARK: - 기동 프롬프트

    func initialPrompt(forRepo repoID: String) -> String? {
        do {
            // 뷰가 다시 그려지며 두 번 불릴 수 있다. 이미 argv 로 실은 것이 열려 있으면 같은 것을 다시 준다 —
            // 다음 것을 꺼내면 보내지도 않은 배분이 `delivered` 가 된다. 소켓으로 간 것이 열려 있으면 실을 것이 없다.
            if let open = try db.read({ try DispatchOps.outstanding(repoID: repoID, in: $0) }) {
                guard open.deliveredSession == "argv" else { return nil }
                return DispatchBody.dispatch(seq: open.seq, repoName: lookups.repoName(repoID), instruction: open.instruction)
            }
            guard let next = try db.read({ try DispatchOps.queued(repoID: repoID, in: $0) }).first else { return nil }
            try db.write { try DispatchOps.markDelivered(next.id, session: "argv", now: now(), in: $0) }
            return DispatchBody.dispatch(seq: next.seq, repoName: lookups.repoName(repoID), instruction: next.instruction)
        } catch { NSLog("[Dure] 기동 프롬프트 실패: \(error)"); return nil }
    }

    func initialPrompt(forOrchestrator workspaceID: String) -> String? {
        do {
            let queued = try db.read { try DispatchOps.queuedRelays(workspaceID: workspaceID, in: $0) }
            guard !queued.isEmpty else { return nil }
            // 먼저 만든다 — 렌더가 실패했는데 전달로 찍히면 묶음이 사라진다.
            let bundle = DispatchBody.bundle(try queued.map(render))
            try db.write { try DispatchOps.markRelaysDelivered(queued.map(\.id), now: now(), in: $0) }
            // 첫 프롬프트도 한 턴이다 — 그 Stop 전에 소켓으로 다음 것을 넣지 않는다. 단 곧 올 `SessionStart` 가
            // 지운다(`didStartOrchestrator`) — `/clear` 처럼 Stop 없이 세션이 바뀌는 길에서 표식이 박히지 않게 하는
            // 쪽을 골랐다. 그래서 SessionStart 와 첫 `UserPromptSubmit` 사이 짧은 틈에 온 relay 는 바로 갈 수 있다.
            orchestratorAwaitingStop.insert(workspaceID)
            return bundle
        } catch { NSLog("[Dure] 조율자 기동 프롬프트 실패: \(error)"); return nil }
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
}
