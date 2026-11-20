import Foundation
import GRDB
import Testing
@testable import Dure

/// Codex 4단계 Task 4 — 계정 한도로 Codex 페인 · Codex 조율자 전달을 멈추고 리셋 뒤 이어 간다(D-46).
/// `limitedUntil` 은 스토어가 Codex 페인에만 채운다 — 여기서는 World 의 페인 뷰에 직접 넣는다.
@MainActor
struct DispatcherLimitTests {

    typealias World = DispatcherTests.World

    func codex(_ w: World, _ repo: String = "r1", thread: String = "T1", until: Int? = nil) {
        w.repoPanes[repo] = .init(started: true, state: .done, address: .codex(socket: "/s", thread: thread),
                                  kind: .codex, limitedUntil: until)
    }

    func codexOrch(_ w: World, until: Int? = nil) {
        w.orch["w1"] = .init(started: true, state: .done, address: .codex(socket: "/o", thread: "O"),
                             kind: .codex, limitedUntil: until)
    }

    func toPane(_ w: World, thread: String = "T1") -> [DispatcherTests.FakeMessaging.Sent] {
        w.inbox.sent.filter { $0.address == .codex(socket: "/s", thread: thread) }
    }

    func toOrch(_ w: World) -> [DispatcherTests.FakeMessaging.Sent] {
        w.inbox.sent.filter { $0.address == .codex(socket: "/o", thread: "O") }
    }

    func limitRelays(_ w: World) throws -> [Relay] {
        try w.db.read { try Relay.filter(Column("kind") == RelayKind.limit.rawValue).order(Column("rowid")).fetchAll($0) }
    }

    func dispatch(_ w: World, _ repo: Repo, _ text: String) throws -> Dispatcher.EnqueueOutcome {
        try w.d.enqueue(workspaceID: "w1", repo: repo, title: nil, instruction: text, toolUseId: nil)
    }

    @Test func limitedRepoQueuesDispatch() throws {
        let w = try World(); codex(w, until: 5000); w.orchIdle()
        #expect(try dispatch(w, w.repoA, "파랑") == .queuedLimited(seq: 1, until: 5000))
        #expect(w.inbox.sent.isEmpty)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .queued)
        // 풀리면(스토어가 limitedUntil 을 비우고 알림) 큐가 흐른다.
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .delivered)
    }

    @Test func limitedPaneQueuesAnswer() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        try w.ask("r1", "어느 쪽?")
        w.d.didStop(repoID: "r1", lastMessage: "어느 쪽?")
        codex(w, until: 7000)
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedLimited(until: 7000))
        #expect(toPane(w).count == 1)
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 2 && toPane(w)[1].content.contains("왼쪽"))
    }

    /// 안 뜬 페인은 한도 중이어도 "안 떠 있다" 가 먼저다 — 사람이 시작해야 하는 것은 그대로다.
    @Test func limitedButNotStartedSaysNotStarted() throws {
        let w = try World()
        w.repoPanes["r1"] = .init(started: false, state: nil, address: nil, kind: .codex, limitedUntil: 5000)
        #expect(try dispatch(w, w.repoA, "x") == .queuedNotStarted(seq: 1))
    }

    /// 막힌 동안 뜬 Codex 페인에 배분을 첫 프롬프트로 싣지 않는다 — 그 첫 턴도 한도로 실패한다. 풀리면 큐로 간다.
    @Test func limitedPaneHoldsLaunchPrompt() throws {
        let w = try World()
        w.repoPanes["r1"] = .init(started: false, state: nil, address: nil, kind: .codex, limitedUntil: 5000)
        _ = try dispatch(w, w.repoA, "x")
        #expect(w.d.initialPrompt(forRepo: "r1") == nil)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .queued)
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "보고")
        codexOrch(w, until: 5000)
        #expect(w.d.initialPrompt(forOrchestrator: "w1") == nil)
        #expect(try w.db.read { try Relay.fetchOne($0) }?.state == .queued)
    }

    @Test func hitWithOpenDispatchKeepsItOpenAndResumesOnce() throws {
        let w = try World(); codex(w); w.orchIdle()
        #expect(try dispatch(w, w.repoA, "일") == .delivered(seq: 1))
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        let open = try #require(try w.db.read { try Dispatch.fetchOne($0) })
        #expect(open.state == .delivered)
        #expect(try limitRelays(w).count == 1)
        #expect(try limitRelays(w)[0].body == DispatchBody.limitNotice(until: 5000))
        #expect(try limitRelays(w)[0].dispatchId == open.id)
        // 막힌 동안 들어온 다음 배분은 큐에 남는다.
        #expect(try dispatch(w, w.repoA, "다음") == .queuedLimited(seq: 2, until: 5000))

        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 2)
        #expect(toPane(w)[1].content == DispatchBody.resumeAfterLimit(open, repoName: "android", kind: .codex))
        // 이어 하기 턴이 끝나기 전에는 다음 배분을 넣지 않는다.
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 2)
        w.d.didStop(repoID: "r1", lastMessage: "아직")
        #expect(toPane(w).count == 2)   // #1 이 응답 대기라 #2 는 아직
        _ = try w.d.complete(repoID: "r1", summary: "끝")
        w.d.didStop(repoID: "r1", lastMessage: "끝")
        #expect(toPane(w).count == 3 && toPane(w)[2].content.contains("다음"))
    }

    @Test func secondHitDoesNotRelayAgain() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        #expect(try limitRelays(w).count == 1)
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(try limitRelays(w).map(\.body) == [DispatchBody.limitNotice(until: 5000), DispatchBody.limitReleased])
        // 새로 막히면 다시 한 번 알린다.
        codex(w, until: 9000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 9000)
        #expect(try limitRelays(w).count == 3)
    }

    @Test func codexOrchestratorGetsOneLimitNoticeAfterReset() throws {
        let w = try World(); codex(w); codexOrch(w)
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000); codexOrch(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        #expect(toOrch(w).isEmpty)
        #expect(try w.db.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.count == 1)
        codex(w, until: nil); codexOrch(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toOrch(w).count == 1)
        let bundle = toOrch(w)[0].content
        #expect(bundle.contains("Codex 페인 배분은 그때까지 큐에 쌓인다"))
        #expect(bundle.contains(DispatchBody.limitReleased))
        #expect(try w.db.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.isEmpty)
    }

    /// 조율자 턴이 한도로 실패하면 그 턴에 넘긴 묶음은 읽히지 않았다 — 다시 큐로 돌려 리셋 뒤 다시 보낸다.
    @Test func orchestratorBundleRequeuedOnLimit() throws {
        let w = try World(); codexOrch(w)
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "보고 하나")
        #expect(toOrch(w).count == 1)
        codexOrch(w, until: 5000)
        w.d.didHitUsageLimit(repoID: nil, workspaceID: "w1", until: 5000)
        let report = try #require(try w.db.read { try Relay.filter(Column("kind") == RelayKind.report.rawValue).fetchOne($0) })
        #expect(report.state == .queued && report.deliveredAt == nil)
        #expect(toOrch(w).count == 1)
        codexOrch(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toOrch(w).count == 2)
        #expect(toOrch(w)[1].content.contains("보고 하나"))
        #expect(toOrch(w)[1].content.contains(DispatchBody.limitReleased))
        // 되돌린 relay 를 실은 묶음은 "다시 보낸다" 로 시작한다. 처음 묶음 · 그 뒤 묶음은 아니다.
        #expect(!toOrch(w)[0].content.contains(DispatchBody.limitResent))
        #expect(toOrch(w)[1].content.hasPrefix(DispatchBody.limitResent + "\n\n"))
        w.d.didStopOrchestrator(workspaceID: "w1")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "보고 둘")
        #expect(toOrch(w).count == 3 && !toOrch(w)[2].content.contains(DispatchBody.limitResent))
    }

    @Test func resentNoteHasNoCodexForbiddenShapes() {
        #expect(!DispatchBody.limitResent.contains("$(") && !DispatchBody.limitResent.contains("<<"))
        #expect(DispatchBody.limitResent.hasPrefix("[두레] "))
    }

    /// 한도로 끊긴 턴에는 Stop 이 없다 — 한도 뒤 Stop 은 실제로 돈 턴(사람이 이어 감)이다. 이어 하기를 보내지 않는다.
    @Test func stopAfterHitCancelsResume() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        w.d.didStop(repoID: "r1", lastMessage: "사람이 이어 감")
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
    }

    /// 응답 대기 중인 배분 — 끊긴 턴은 사람이 친 것이다. 기억하지 않고 이어 하지 않는다.
    @Test func waitingDispatchIsNotRecordedOnHit() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        w.d.didStop(repoID: "r1", lastMessage: "물어봄")
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .waiting)
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .waiting)
    }

    /// 풀릴 때 사람이 그 페인에서 턴을 돌리고 있으면 끼어들지 않는다.
    @Test func runningPaneAtReleaseIsNotResumed() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        w.repoPanes["r1"] = .init(started: true, state: .running, address: .codex(socket: "/s", thread: "T1"), kind: .codex)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
    }

    /// 풀린 직후 다시 막힘 — 막기만 하고 조율자에게 다시 알리지 않는다(풀림 안내도 없음). 끊긴 배분은 그래도 이어 한다.
    @Test func quietHitBlocksWithoutRelay() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000, announce: false)
        #expect(try limitRelays(w).isEmpty)
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(try limitRelays(w).isEmpty)
        #expect(toPane(w).count == 2)
    }

    /// 묶음을 읽은 턴이 Stop 으로 끝났으면 그 뒤의 한도 실패는 다른 턴이다 — 다시 보내지 않는다.
    @Test func orchestratorBundleReadBeforeLimitIsNotRequeued() throws {
        let w = try World(); codexOrch(w)
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "보고 하나")
        w.d.didStopOrchestrator(workspaceID: "w1")
        codexOrch(w, until: 5000)
        w.d.didHitUsageLimit(repoID: nil, workspaceID: "w1", until: 5000)
        let report = try #require(try w.db.read { try Relay.filter(Column("kind") == RelayKind.report.rawValue).fetchOne($0) })
        #expect(report.state == .delivered)
    }

    @Test func claudePaneUnaffectedByCodexLimit() throws {
        let w = try World(); codex(w); w.idle("r2", session: "cc-b"); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        #expect(try dispatch(w, w.repoB, "ios 일") == .delivered(seq: 2))
        #expect(w.inbox.sent.contains { $0.session == "cc-b" && $0.content.contains("ios 일") })
    }

    /// 끊긴 턴이 배분 밖의 것(배분 없는 질문의 답)이면 이어 할 것이 없다 — Stop 대기를 풀어 큐가 막히지 않게.
    @Test func hitWithoutOpenDispatchFreesPane() throws {
        let w = try World(); codex(w); w.orchIdle()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .question, body: "배분 밖 질문")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "답") == .delivered)
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(try dispatch(w, w.repoA, "새 일") == .delivered(seq: 1))
    }

    /// 이어 하기 전에 배분이 닫혔으면(사람이 완료로 닫음) 보내지 않는다.
    @Test func closedInterruptedDispatchIsNotResumed() throws {
        let w = try World(); codex(w); w.orchIdle()
        _ = try dispatch(w, w.repoA, "일")
        codex(w, until: 5000)
        w.d.didHitUsageLimit(repoID: "r1", workspaceID: "w1", until: 5000)
        let id = try #require(w.d.outstandingDispatchID(repoID: "r1"))
        #expect(try w.d.closeByHuman(id, workspaceID: "w1"))
        codex(w, until: nil)
        w.d.didReleaseUsageLimit()
        #expect(toPane(w).count == 1)
        // 끊긴 턴의 Stop 은 오지 않는다 — 대기를 풀어 다음 배분이 간다.
        #expect(try dispatch(w, w.repoA, "새 일") == .delivered(seq: 2))
    }
}
