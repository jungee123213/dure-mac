import Foundation
import GRDB
import Testing
@testable import Dure

/// 단계 4 — 큐가 언제 흐르고 언제 멈추는가. DB 는 메모리, 소켓은 가짜.
/// `Dispatcher` 는 앱 타깃 기본값으로 메인액터에 묶이는데 테스트 타깃은 그 기본값이 없어 직접 표시한다.
@MainActor
struct DispatcherTests {

    final class FakeInbox: InboxSending {
        var sent: [(session: String, content: String)] = []
        var failNext = 0
        func send(_ content: String, toClaudeSession id: String) throws {
            if failNext > 0 { failNext -= 1; throw Inbox.Problem.noSocket }
            sent.append((id, content))
        }
    }

    /// 중첩 타입은 바깥의 액터 표시를 물려받지 않는다 — `lazy var d` 가 `Dispatcher` 를 만들므로 따로 단다.
    @MainActor
    final class World {
        var repoPanes: [String: Dispatcher.PaneView] = [:]
        var orch: [String: Dispatcher.PaneView] = [:]
        let inbox = FakeInbox()
        var clock = 1_000
        let db: DatabaseQueue
        let repoA = Repo(id: "r1", workspaceId: "w1", path: "/a/android", label: "android")
        let repoB = Repo(id: "r2", workspaceId: "w1", path: "/a/ios")
        lazy var d = Dispatcher(db: db, inbox: inbox, lookups: .init(
            repoPane: { [unowned self] in self.repoPanes[$0] ?? .init(started: false, state: nil, claudeSessionID: nil) },
            orchestratorPane: { [unowned self] in self.orch[$0] ?? .init(started: false, state: nil, claudeSessionID: nil) },
            repoName: { [unowned self] in $0 == "r1" ? "android" : "ios" }),
            now: { [unowned self] in self.clock })

        init() throws {
            db = try DatabaseQueue()
            try AppDatabase.migrator.migrate(db)
            try db.write { db in
                try Workspace(id: "w1", name: "모바일").insert(db)
                try repoA.insert(db); try repoB.insert(db)
            }
        }
        func idle(_ repo: String, session: String = "cc-\(UUID().uuidString.prefix(4))") {
            repoPanes[repo] = .init(started: true, state: .done, claudeSessionID: session)
        }
        func busy(_ repo: String) { repoPanes[repo] = .init(started: true, state: .running, claudeSessionID: "cc") }
        func orchIdle() { orch["w1"] = .init(started: true, state: .done, claudeSessionID: "cc-orch") }
    }

    @Test func 놀고_있는_페인에는_바로_전달한다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        let out = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "파랑으로", toolUseId: "tu")
        #expect(out == .delivered(seq: 1))
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].session == "cc-a")
        #expect(w.inbox.sent[0].content.hasPrefix("[두레] 조율자 배분 #1 — android\n파랑으로\n"))
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .delivered && row?.deliveredSession == "cc-a" && row?.toolUseId == "tu")
    }

    /// Review Focus 1.
    @Test func 일하는_페인에는_보관했다가_Stop_뒤에_넣는다() throws {
        let w = try World(); w.busy("r1")
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil) == .queuedBusy(seq: 1))
        #expect(w.inbox.sent.isEmpty)
        w.idle("r1", session: "cc-b")
        w.d.didStop(repoID: "r1", lastMessage: "앞 일 끝")        // 앞 일은 배분이 아니었다 → 닫을 것 없음, 큐만 흐른다
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].session == "cc-b")
        #expect(try w.db.read { try Relay.fetchCount($0) } == 0)   // 배분 아닌 턴의 Stop 은 보고하지 않는다
    }

    @Test func 안_뜬_페인은_큐에_두고_시작할_때_싣는다() throws {
        let w = try World()
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", toolUseId: nil) == .queuedNotStarted(seq: 1))
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil)
        #expect(w.d.queueCount(repoID: "r1") == 2)
        let prompt = w.d.initialPrompt(forRepo: "r1")
        #expect(prompt?.contains("배분 #1 — android\n첫") == true)
        #expect(w.d.queueCount(repoID: "r1") == 1)
        let row = try w.db.read { try Dispatch.filter(Column("seq") == 1).fetchOne($0) }
        #expect(row?.state == .delivered && row?.deliveredSession == "argv")
        #expect(w.d.initialPrompt(forRepo: "r2") == nil)
    }

    @Test func 전달_뒤_첫_Stop_이_닫고_조율자에게_올린다() throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.clock = 2_000
        w.d.didStop(repoID: "r1", lastMessage: "다 했다")
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .done && row?.result == "다 했다" && row?.doneAt == 2_000)
        // 조율자가 놀고 있으니 바로 전달됐다
        let toOrch = w.inbox.sent.filter { $0.session == "cc-orch" }
        #expect(toOrch.count == 1)
        #expect(toOrch[0].content.hasPrefix("[두레] ‹android› 배분 #1 끝남 (") && toOrch[0].content.hasSuffix("\n다 했다"))
        #expect(try w.db.read { try Relay.fetchOne($0) }?.state == .delivered)
        // 그다음 사람의 턴은 보고하지 않는다
        w.d.didStop(repoID: "r1", lastMessage: "사람과 잡담")
        #expect(w.inbox.sent.filter { $0.session == "cc-orch" }.count == 1)
    }

    @Test func 전달_뒤에는_상태가_done_이어도_다음_것을_안_넣는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil) == .queuedBusy(seq: 2))
        #expect(w.inbox.sent.count == 1)
        w.d.didStop(repoID: "r1", lastMessage: "하나 끝")
        #expect(w.inbox.sent.count == 2)     // 둘이 흘렀다 (조율자가 안 떠 있어 보고는 큐에)
        #expect(try w.db.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.count == 1)
    }

    @Test func 조율자가_안_떠_있으면_쌓았다가_시작_때_묶는다() throws {
        let w = try World(); w.idle("r1")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "a", toolUseId: nil)
        w.d.didStop(repoID: "r1", lastMessage: "끝 a")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r2", kind: .question, body: "왜?")
        let bundle = try #require(w.d.initialPrompt(forOrchestrator: "w1"))
        #expect(bundle.contains("배분 #1 끝남") && bundle.contains("\n\n---\n\n") && bundle.contains("‹ios› 질문"))
        #expect(w.d.initialPrompt(forOrchestrator: "w1") == nil)
    }

    @Test func 조율자가_일하는_중이면_Stop_뒤에_올린다() throws {
        let w = try World(); w.idle("r1")
        w.orch["w1"] = .init(started: true, state: .running, claudeSessionID: "cc-orch")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "중간")
        #expect(w.inbox.sent.isEmpty)
        w.orchIdle(); w.d.didStopOrchestrator(workspaceID: "w1")
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.contains("‹android› 보고"))
    }

    /// 최종 리뷰 I-2 — 조율자도 레포와 같다. 묶음을 넣은 뒤 그 턴의 Stop 전에는 상태가 done 이어도 다음 것을 안 넣는다.
    @Test func 조율자도_전달_뒤_Stop_전에는_다음_묶음을_안_넣는다() throws {
        let w = try World(); w.orchIdle()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "첫째")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r2", kind: .question, body: "둘째")
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.contains("첫째"))
        #expect(try w.db.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.count == 1)
        w.d.didStopOrchestrator(workspaceID: "w1")
        #expect(w.inbox.sent.count == 2 && w.inbox.sent[1].content.contains("둘째"))
    }

    /// 새 조율자 세션(`SessionStart` · `/clear`)은 옛 턴의 Stop 을 기다리지 않는다.
    @Test func 조율자_SessionStart_가_기다림을_푼다() throws {
        let w = try World(); w.orchIdle()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "첫째")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "둘째")
        #expect(w.inbox.sent.count == 1)
        w.d.didStartOrchestrator(workspaceID: "w1")
        #expect(w.inbox.sent.count == 2)
    }

    /// 기동 프롬프트로 실은 묶음도 한 턴이다. 죽으면 표식을 지운다(그 세션의 Stop 은 오지 않는다).
    @Test func 조율자_기동_프롬프트_뒤에도_기다리고_죽으면_푼다() throws {
        let w = try World()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "첫째")
        #expect(w.d.initialPrompt(forOrchestrator: "w1") != nil)
        w.orchIdle()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "둘째")
        #expect(w.inbox.sent.isEmpty)
        w.d.didDieOrchestrator(workspaceID: "w1")
        w.d.pumpOrchestrator("w1")
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.contains("둘째"))
    }

    @Test func 소켓_실패는_큐에_남기고_세_번이면_포기한다() throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        w.inbox.failNext = 3
        // 페인은 놀고 있었으니 Stop 을 기다리라고 하면 안 된다 (I-3)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil) == .deliveryFailed(seq: 1, attempts: 1))
        w.d.retryPending()           // 2회 — 훅 없이 주기 틱만으로 재시도된다
        w.d.retryPending()           // 3회 → 포기
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .failed && row?.attempts == 3)
        let fail = w.inbox.sent.filter { $0.session == "cc-orch" }
        #expect(fail.count == 1 && fail[0].content.hasPrefix("[두레] ‹android› 배분 #1 실패"))
    }

    @Test func 밀린_것이_없으면_재시도해도_아무것도_안_보낸다() throws {
        let w = try World(); w.idle("r1"); w.orchIdle()
        w.d.retryPending()
        #expect(w.inbox.sent.isEmpty)
        // 아직 시도 안 한 큐(안 뜬 페인)도 건드리지 않는다
        let w2 = try World()
        _ = try w2.d.enqueue(workspaceID: "w1", repo: w2.repoB, title: nil, instruction: "x", toolUseId: nil)
        w2.idle("r2"); w2.d.retryPending()
        #expect(w2.inbox.sent.isEmpty)
    }

    /// I-2 — 뷰가 다시 그려지며 두 번 불려도 다음 것을 꺼내지 않는다.
    @Test func 기동_프롬프트는_두_번_불려도_같다() throws {
        let w = try World()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil)
        let a = try #require(w.d.initialPrompt(forRepo: "r1"))
        let b = w.d.initialPrompt(forRepo: "r1")
        #expect(a == b)
        let rows = try w.db.read { try Dispatch.order(Column("seq")).fetchAll($0) }
        #expect(rows.filter { $0.state == .delivered }.count == 1)
        #expect(rows[1].state == .queued)
    }

    @Test func 소켓으로_간_배분이_열려_있으면_기동_프롬프트가_없다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil)
        #expect(w.d.initialPrompt(forRepo: "r1") == nil)
        #expect(w.d.queueCount(repoID: "r1") == 1)
    }

    @Test func 페인이_죽으면_열린_배분을_실패로_닫는다() throws {
        let w = try World(); w.idle("r1"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.d.didDie(repoID: "r1")
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.failure == "페인 종료")
        #expect(w.inbox.sent.last?.content.contains("실패") == true)
    }

    /// Review Focus 3.
    @Test func 앱_시작_복구() throws {
        let w = try World(); w.idle("r1")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        let fresh = Dispatcher(db: w.db, inbox: w.inbox, lookups: w.d.lookups, now: { 5 })
        fresh.recoverOnLaunch()
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.failure == "앱 종료")
        #expect(try w.db.read { try Relay.fetchOne($0) }?.kind == .failure)
    }

    @Test func 번호나_id_로_취소한다() throws {
        let w = try World()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        let id = try #require(try w.db.read { try Dispatch.fetchOne($0) }?.id)
        #expect(try w.d.cancel(.seq(9), workspaceID: "w1") == false)
        #expect(try w.d.cancel(.seq(1), workspaceID: "w1") == true)
        #expect(try w.d.cancel(.id(id), workspaceID: "w1") == false)   // 이미 취소됨
        #expect(w.d.history(workspaceID: "w1").first?.state == .cancelled)
    }

    /// I-1 — id 로 취소해도 다른 워크스페이스의 배분은 못 건드린다.
    @Test func 다른_워크스페이스의_id_로는_취소하지_못한다() throws {
        let w = try World()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        let id = try #require(try w.db.read { try Dispatch.fetchOne($0) }?.id)
        #expect(try w.d.cancel(.id(id), workspaceID: "w2") == false)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .queued)
    }
}
