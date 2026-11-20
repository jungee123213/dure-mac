import Foundation
import GRDB
import Testing
@testable import Dure

/// 단계 4 — 큐가 언제 흐르고 언제 멈추는가. DB 는 메모리, 소켓은 가짜.
/// `Dispatcher` 는 앱 타깃 기본값으로 메인액터에 묶이는데 테스트 타깃은 그 기본값이 없어 직접 표시한다.
@MainActor
struct DispatcherTests {

    /// 출구 가짜 — 받은 주소를 그대로 적는다. `session` 은 Claude 면 세션 id, Codex 면 스레드 id.
    final class FakeMessaging: PaneMessaging {
        struct Sent {
            var address: PaneAddress
            var content: String
            var session: String { address.sessionKey }
        }
        var sent: [Sent] = []
        var failNext = 0
        func send(_ content: String, to address: PaneAddress) throws {
            if failNext > 0 {
                failNext -= 1
                switch address {
                case .claude: throw Inbox.Problem.noSocket
                case .codex: throw CodexQueueSender.Problem.exit(1, "failed to connect")
                }
            }
            sent.append(Sent(address: address, content: content))
        }
    }

    /// 중첩 타입은 바깥의 액터 표시를 물려받지 않는다 — `lazy var d` 가 `Dispatcher` 를 만들므로 따로 단다.
    @MainActor
    final class World {
        var repoPanes: [String: Dispatcher.PaneView] = [:]
        var orch: [String: Dispatcher.PaneView] = [:]
        let inbox = FakeMessaging()
        var clock = 1_000
        let db: DatabaseQueue
        let repoA = Repo(id: "r1", workspaceId: "w1", path: "/a/android", label: "android")
        let repoB = Repo(id: "r2", workspaceId: "w1", path: "/a/ios")
        lazy var d = Dispatcher(db: db, messaging: inbox, lookups: .init(
            repoPane: { [unowned self] in self.repoPanes[$0] ?? .init(started: false, state: nil, address: nil) },
            orchestratorPane: { [unowned self] in self.orch[$0] ?? .init(started: false, state: nil, address: nil) },
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
            repoPanes[repo] = .init(started: true, state: .done, address: .claude(session: session))
        }
        func busy(_ repo: String) { repoPanes[repo] = .init(started: true, state: .running, address: .claude(session: "cc")) }
        func orchIdle() { orch["w1"] = .init(started: true, state: .done, address: .claude(session: "cc-orch")) }
        /// 레포 페인의 `ask_orchestrator` — 그 페인의 열린 배분에 묶인 질문 relay.
        func ask(_ repo: String, _ text: String) throws {
            try d.relay(workspaceID: "w1", dispatchID: d.outstandingDispatchID(repoID: repo), repoID: repo,
                        kind: .question, body: text)
        }
    }

    func gitDone(_ w: World, _ c: DispatchCompletion?) throws -> String? {
        w.idle("r1", session: "cc-a"); w.orchIdle()
        let git = c == nil ? DispatchGitRequest.none
            : DispatchGitRequest(mode: .newIssue, issueTitle: "t", issueBody: "b", scope: .commit)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", git: git, toolUseId: nil)
        _ = try w.d.complete(repoID: "r1", summary: "다 했다", completion: c ?? .init())
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .done)
        return try w.db.read { try Relay.filter(Column("kind") == RelayKind.completion.rawValue).fetchOne($0) }?.body
    }

    @Test func 완료_보고에_git_메모가_붙는다() throws {
        let w = try World()
        let body = try gitDone(w, .init(issueNumber: 165, branch: "feat/#165/x", prNumber: nil))
        #expect(body == "이슈 #165 · 브랜치 feat/#165/x\n다 했다")
    }

    @Test func 새_이슈인데_번호_없이_끝나면_경고가_간다() throws {
        let w = try World()
        let body = try gitDone(w, .init())
        #expect(body?.contains("이슈 번호 없음") == true)
    }

    @Test func git_없음_배분은_보고_본문이_그대로다() throws {
        let w = try World()
        #expect(try gitDone(w, nil) == "다 했다")
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
    /// 이슈 #27 — 소켓 턴은 `UserPromptSubmit` 이 안 뜰 수 있어 페인 상태가 `done` 으로 남는다.
    /// 그 상태만 믿으면 complete 직후 다음 배분이 끼어들고, 이어 온 이전 턴의 Stop 이 그것을 waiting 으로 만든다.
    @Test func complete_직후에도_Stop_전에는_다음_배분을_안_넣는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "first", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "second", toolUseId: nil)
        _ = try w.d.complete(repoID: "r1", summary: "first finished")
        #expect(w.inbox.sent.count == 1)
        w.d.didStop(repoID: "r1", lastMessage: "first finished")
        #expect(w.inbox.sent.count == 2)
        let open = try w.db.read { try DispatchOps.outstanding(repoID: "r1", in: $0) }
        #expect(open?.state == .delivered)
    }

    @Test func 새_세션_시작이_Stop_대기를_풀어_큐가_흐른다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "first", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "second", toolUseId: nil)
        _ = try w.d.complete(repoID: "r1", summary: "done")
        #expect(w.inbox.sent.count == 1)
        w.idle("r1", session: "cc-b")                       // /clear — 옛 세션의 Stop 은 오지 않는다
        w.d.didStart(repoID: "r1", session: "cc-b", source: "clear")
        #expect(w.inbox.sent.count == 2 && w.inbox.sent[1].session == "cc-b")
    }

    @Test func 페인이_죽으면_Stop_대기를_풀어_다음_시작에_흐른다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "first", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "second", toolUseId: nil)
        w.d.didDie(repoID: "r1")
        w.idle("r1", session: "cc-c")
        w.d.didStart(repoID: "r1", session: "cc-c", source: "startup")
        #expect(w.inbox.sent.count == 2)
    }

    @Test func 사람이_닫은_직후에도_Stop_전에는_다음_배분을_안_넣는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "first", toolUseId: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "second", toolUseId: nil)
        let first = try w.db.read { try Dispatch.filter(Column("seq") == 1).fetchOne($0) }!
        _ = try w.d.closeByHuman(first.id, workspaceID: "w1")
        #expect(w.inbox.sent.count == 1)
        w.d.didStop(repoID: "r1", lastMessage: "x")
        #expect(w.inbox.sent.count == 2)
    }

    @Test func 일하는_페인에는_보관했다가_Stop_뒤에_넣는다() throws {
        let w = try World(); w.busy("r1")
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil) == .queuedBusy(seq: 1))
        #expect(w.inbox.sent.isEmpty)
        w.idle("r1", session: "cc-b")
        w.d.didStop(repoID: "r1", lastMessage: "앞 일 끝")        // 앞 일은 배분이 아니었다 → 닫을 것 없음, 큐만 흐른다
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].session == "cc-b")
        #expect(try w.db.read { try Relay.fetchCount($0) } == 0)   // 배분 아닌 턴의 Stop 은 보고하지 않는다
    }

    /// 주소(Claude 세션 · Codex 서버 소켓 + 스레드)를 아직 모르는 페인 — 떠 있고 놀고 있어도 큐에 남는다.
    /// Codex 페인은 스레드 주소가 잡히기 전(기동 직후 · Task 4 연결 전)이 이 경우다. (1단계 Review Focus 5 의 고정 테스트를 새 필드로)
    @Test func 주소가_없는_페인으로는_나가지_않는다() throws {
        let w = try World()
        w.repoPanes["r1"] = .init(started: true, state: .started, address: nil)
        let out = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        #expect(out == .queuedBusy(seq: 1))
        #expect(w.inbox.sent.isEmpty)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .queued)
        w.repoPanes["r1"] = .init(started: true, state: .done, address: nil)
        w.d.didStop(repoID: "r1", lastMessage: "끝")
        #expect(w.inbox.sent.isEmpty)
        #expect(w.d.queueCount(repoID: "r1") == 1)
    }

    // MARK: - Codex 페인 (2단계 Task 3)

    func codexIdle(_ w: World, _ repo: String = "r1", thread: String = "T1") {
        w.repoPanes[repo] = .init(started: true, state: .done, address: .codex(socket: "/s", thread: thread))
    }

    @Test func Codex_페인에는_codex_주소로_배분이_간다() throws {
        let w = try World(); codexIdle(w)
        let out = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "파랑으로", toolUseId: nil)
        #expect(out == .delivered(seq: 1))
        #expect(w.inbox.sent.count == 1)
        #expect(w.inbox.sent[0].address == .codex(socket: "/s", thread: "T1"))
        #expect(w.inbox.sent[0].content.hasPrefix("[두레] 조율자 배분 #1 — android\n파랑으로\n"))
        // SessionStart 의 session_id 와 같은 공간 — Codex 는 스레드 id 가 곧 session_id 다.
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.deliveredSession == "T1")
    }

    @Test func Codex_페인은_Codex_판_본문을_받는다() throws {
        let w = try World()
        w.repoPanes["r1"] = .init(started: true, state: .done, address: .codex(socket: "/s", thread: "T1"), kind: .codex)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x",
                            git: .init(mode: .newIssue, issueTitle: "t", issueBody: "b", scope: .commit), toolUseId: nil)
        let c = try #require(w.inbox.sent.first?.content)
        #expect(c.contains("AGENTS.md") && !c.contains("<<'EOF'"))
    }

    @Test func Claude_조율자에서_Codex_페인으로_가는_배분과_Codex_페인의_보고가_각자_출구로_간다() throws {
        let w = try World(); codexIdle(w); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        #expect(try w.d.complete(repoID: "r1", summary: "다 했습니다") == 1)
        #expect(w.inbox.sent.count == 2)
        #expect(w.inbox.sent[0].address == .codex(socket: "/s", thread: "T1"))
        #expect(w.inbox.sent[1].address == .claude(session: "cc-orch"))
        #expect(w.inbox.sent[1].content.contains("배분 #1 끝남"))
        // Codex 페인의 질문에 온 조율자 답도 Codex 출구로 간다.
        w.d.didStop(repoID: "r1", lastMessage: nil)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "y", toolUseId: nil)
        try w.ask("r1", "어느 쪽?")
        w.d.didStop(repoID: "r1", lastMessage: "어느 쪽?")
        w.d.didStopOrchestrator(workspaceID: "w1")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .delivered)
        let last = try #require(w.inbox.sent.last)
        #expect(last.address == .codex(socket: "/s", thread: "T1"))
        #expect(last.content.hasPrefix("[두레] 조율자 답 (배분 #2)"))
    }

    @Test func Codex_페인이_새_스레드를_열면_열린_배분이_실패로_닫힌다() throws {
        let w = try World(); codexIdle(w, thread: "T1"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        // `/new` — 새 스레드 id + source "startup"
        codexIdle(w, thread: "T2")
        w.d.didStart(repoID: "r1", session: "T2", source: "startup")
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .failed && row?.failure == "세션 재시작")
        #expect(w.inbox.sent.last?.address == .claude(session: "cc-orch"))
        #expect(w.inbox.sent.last?.content.contains("배분 #1 실패") == true)
    }

    @Test func Codex_전달이_실패하면_재시도_횟수가_는다() throws {
        let w = try World(); codexIdle(w); w.orchIdle()
        w.inbox.failNext = 1
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
                == .deliveryFailed(seq: 1, attempts: 1))
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .queued)
        w.d.retryPending()
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .delivered && row?.attempts == 1 && row?.deliveredSession == "T1")
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].address == .codex(socket: "/s", thread: "T1"))
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

    @Test func 안_뜬_페인의_기동_프롬프트에도_이슈_초안이_실린다() throws {
        let w = try World()
        let git = DispatchGitRequest(mode: .newIssue, issueTitle: "[FEAT] 공유", issueBody: "본문", scope: .commit)
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", git: git, toolUseId: nil)
        let p = try #require(w.d.initialPrompt(forRepo: "r1"))
        #expect(p.contains("## 이슈 초안") && p.contains("제목: [FEAT] 공유"))
        // v8 이전 꼴(git 칸 없음) 행
        try w.db.write { db in
            try db.execute(sql: """
                INSERT INTO dispatch (id, workspace_id, seq, repo_id, instruction, state, attempts, created_at)
                VALUES ('old', 'w1', 99, 'r2', '옛 지시', 'queued', 0, 1)
                """)
        }
        let old = try #require(w.d.initialPrompt(forRepo: "r2"))
        #expect(old.contains("이슈 · 브랜치 · 커밋을 하지 않는다"))
        #expect(!old.contains("## "))
    }

    /// 이슈 #24 — 질문으로 멈춘 턴은 완료가 아니다. 응답 대기로 두고 조율자에게 "끝남" 을 보내지 않는다.
    @Test func 질문으로_끝난_턴은_응답_대기이고_끝남을_안_보낸다() throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.clock = 2_000
        w.d.didStop(repoID: "r1", lastMessage: "A 로 할까요, B 로 할까요?")
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .waiting && row?.result == "A 로 할까요, B 로 할까요?" && row?.doneAt == nil)
        #expect(w.inbox.sent.filter { $0.session == "cc-orch" }.isEmpty)
        #expect(w.d.outstandingDispatchID(repoID: "r1") == row?.id)     // 그 페인은 아직 그 일을 하는 중이다
    }

    /// 이슈 #24 — 완료는 레포 에이전트가 `complete` 로 선언한다.
    @Test func complete_가_닫고_조율자에게_올린다() throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.d.didStop(repoID: "r1", lastMessage: "질문")              // 사람에게 묻고
        w.clock = 3_000
        #expect(try w.d.complete(repoID: "r1", summary: "다 했다") == 1)   // 답을 받은 뒤 끝냈다
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .done && row?.result == "다 했다" && row?.doneAt == 3_000)
        let toOrch = w.inbox.sent.filter { $0.session == "cc-orch" }
        #expect(toOrch.count == 1)
        #expect(toOrch[0].content.hasPrefix("[두레] ‹android› 배분 #1 끝남 (") && toOrch[0].content.hasSuffix("\n다 했다"))
        // 그 턴의 Stop · 이후 사람의 턴은 보고하지 않는다
        w.d.didStopOrchestrator(workspaceID: "w1")
        w.d.didStop(repoID: "r1", lastMessage: "사람과 잡담")
        #expect(w.inbox.sent.filter { $0.session == "cc-orch" }.count == 1)
        #expect(try w.d.complete(repoID: "r1", summary: "또") == nil)       // 열린 배분이 없다
    }

    @Test func 응답_대기_중에는_다음_배분을_안_넣고_complete_뒤에_넣는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil) == .queuedBusy(seq: 2))
        #expect(w.inbox.sent.count == 1)
        w.d.didStop(repoID: "r1", lastMessage: "어떻게 할까요?")
        #expect(w.inbox.sent.count == 1)     // 질문 중인 페인에 끼어들지 않는다
        w.busy("r1")
        _ = try w.d.complete(repoID: "r1", summary: "하나 끝")
        #expect(w.inbox.sent.count == 1)     // complete 를 부른 턴이 아직 돈다
        w.idle("r1", session: "cc-a")
        w.d.didStop(repoID: "r1", lastMessage: "하나 끝")
        #expect(w.inbox.sent.count == 2)     // 둘이 흘렀다 (조율자가 안 떠 있어 보고는 큐에)
        #expect(try w.db.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.count == 1)
    }

    /// 이슈 #24 — 에이전트가 complete 를 잊었을 때 사람이 대시보드에서 닫는다. 마지막 답이 결과로 올라간다.
    @Test func 사람이_완료로_닫는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.d.didStop(repoID: "r1", lastMessage: "작업을 마쳤습니다")
        let id = try #require(w.d.outstandingDispatchID(repoID: "r1"))
        #expect(try w.d.closeByHuman(id, workspaceID: "w1") == true)
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .done && row?.result == "작업을 마쳤습니다")
        #expect(w.inbox.sent.last?.content.contains("배분 #1 끝남") == true)
        #expect(w.inbox.sent.last?.content.hasSuffix("\n작업을 마쳤습니다") == true)
        #expect(try w.d.closeByHuman(id, workspaceID: "w1") == false)        // 이미 닫힘
    }

    @Test func 다른_워크스페이스의_배분은_닫지_못한다() throws {
        let w = try World(); w.idle("r1")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        let id = try #require(w.d.outstandingDispatchID(repoID: "r1"))
        #expect(try w.d.closeByHuman(id, workspaceID: "w2") == false)
    }

    /// 이슈 #24 — 기동 프롬프트(argv)로 실은 배분은 그 페인의 첫 세션이 이어받는다.
    @Test func argv_로_실은_배분은_첫_세션이_이어받는다() throws {
        let w = try World()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", toolUseId: nil)
        _ = w.d.initialPrompt(forRepo: "r1")
        w.idle("r1", session: "cc-new")
        w.d.didStart(repoID: "r1", session: "cc-new", source: "startup")
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .delivered && row?.deliveredSession == "cc-new")
    }

    /// 이슈 #24 — 열린 배분이 있는데 세션이 바뀌면(`/clear` · 다른 세션) 그 배분은 끝나지 않는다. 실패로 닫고 알린다.
    @Test(arguments: [("cc-a", "clear"), ("cc-b", "startup"), ("cc-b", "resume")])
    func 세션이_바뀌면_열린_배분을_실패로_닫는다(_ session: String, _ source: String) throws {
        let w = try World(); w.idle("r1", session: "cc-a"); w.orchIdle()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.idle("r1", session: session)
        w.d.didStart(repoID: "r1", session: session, source: source)
        let row = try w.db.read { try Dispatch.fetchOne($0) }
        #expect(row?.state == .failed && row?.failure == "세션 재시작")
        #expect(w.inbox.sent.last?.content.contains("배분 #1 실패") == true)
    }

    @Test(arguments: ["compact", "resume"])
    func 같은_세션의_압축_재개는_배분을_유지한다(_ source: String) throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.d.didStart(repoID: "r1", session: "cc-a", source: source)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .delivered)
    }

    @Test func 조율자가_안_떠_있으면_쌓았다가_시작_때_묶는다() throws {
        let w = try World(); w.idle("r1")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "a", toolUseId: nil)
        _ = try w.d.complete(repoID: "r1", summary: "끝 a")
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r2", kind: .question, body: "왜?")
        let bundle = try #require(w.d.initialPrompt(forOrchestrator: "w1"))
        #expect(bundle.contains("배분 #1 끝남") && bundle.contains("\n\n---\n\n") && bundle.contains("‹ios› 질문"))
        #expect(w.d.initialPrompt(forOrchestrator: "w1") == nil)
    }

    @Test func 조율자가_일하는_중이면_Stop_뒤에_올린다() throws {
        let w = try World(); w.idle("r1")
        w.orch["w1"] = .init(started: true, state: .running, address: .claude(session: "cc-orch"))
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
        let fresh = Dispatcher(db: w.db, messaging: w.inbox, lookups: w.d.lookups, now: { 5 })
        w.d.didStop(repoID: "r1", lastMessage: "질문")         // 응답 대기도 앱이 꺼지면 영영 안 닫힌다
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

    // MARK: - 조율자 답 (이슈 #43)

    @Test func 열린_배분이_응답_대기면_답이_바로_간다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        w.d.didStop(repoID: "r1", lastMessage: "조율자에게 물었다")
        try w.ask("r1", "API 는 v2 로?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "v2 로 간다") == .delivered)
        let last = try #require(w.inbox.sent.last)
        #expect(last.session == "cc-a" && last.content.hasPrefix("[두레] 조율자 답 (배분 #1)"))
        #expect(last.content.contains("질문: API 는 v2 로?\nv2 로 간다"))
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .delivered)   // 페인이 그 배분을 다시 하는 중
        #expect(w.d.answers(workspaceID: "w1").first?.state == .delivered)
    }

    @Test func 답이_간_뒤에도_큐의_다음_배분은_막힌다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil) == .queuedBusy(seq: 2))
        w.d.didStop(repoID: "r1", lastMessage: "물었다")
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .delivered)
        let two = try w.db.read { try Dispatch.filter(Column("seq") == 2).fetchOne($0) }
        #expect(two?.state == .queued)
        #expect(w.inbox.sent.count == 2)    // 배분 #1 + 답
    }

    @Test func 턴이_도는_중이면_답은_Stop_뒤에_배분보다_먼저_간다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        try w.ask("r1", "어느 쪽?")                                   // 배분 #1 의 턴 한가운데서 물었다
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedBusy)
        #expect(w.inbox.sent.count == 1)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil) == .queuedBusy(seq: 2))
        w.d.didStop(repoID: "r1", lastMessage: "답을 기다린다")
        #expect(w.inbox.sent.count == 2)
        #expect(w.inbox.sent.last?.content.hasPrefix("[두레] 조율자 답 (배분 #1)") == true)
        let rows = try w.db.read { try Dispatch.order(Column("seq")).fetchAll($0) }
        #expect(rows[0].state == .delivered && rows[1].state == .queued)
    }

    @Test func argv_첫_턴_중에는_답이_끼어들지_않는다() throws {
        let w = try World()
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", toolUseId: nil)
        _ = try #require(w.d.initialPrompt(forRepo: "r1"))
        w.repoPanes["r1"] = .init(started: true, state: .started, address: .claude(session: "cc-new"))
        w.d.didStart(repoID: "r1", session: "cc-new", source: "startup")
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedBusy)
        #expect(w.inbox.sent.isEmpty)
        #expect(w.d.answers(workspaceID: "w1").first?.state == .queued)
    }

    @Test func 배분_밖_질문의_답은_배분_상태를_바꾸지_않는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        try w.ask("r1", "이 레포 규칙이 뭐지?")                         // 열린 배분 없음
        let before = try w.db.read { try Dispatch.fetchAll($0) }
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "README 를 봐라") == .delivered)
        #expect(w.inbox.sent.last?.content.hasPrefix("[두레] 조율자 답 (배분 없음)") == true)
        #expect(try w.db.read { try Dispatch.fetchAll($0) } == before)
        #expect(w.d.answers(workspaceID: "w1").first?.dispatchId == nil)
    }

    /// 배분 밖 질문 → 그 뒤 배분이 열림 → 답은 그 배분이 응답 대기일 때만 가고, 그 배분을 되돌리지 않는다.
    @Test func 배분_밖_질문의_답은_나중에_열린_배분을_되돌리지_않는다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        try w.ask("r1", "이 레포 규칙이 뭐지?")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "x", toolUseId: nil)
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "README") == .queuedBusy)   // 배분 #1 턴이 돈다
        #expect(w.inbox.sent.count == 1)
        w.d.didStop(repoID: "r1", lastMessage: "물었다")                 // 배분 #1 응답 대기 → 답이 간다
        #expect(w.inbox.sent.count == 2 && w.inbox.sent[1].content.hasPrefix("[두레] 조율자 답 (배분 없음)"))
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .waiting)
    }

    @Test func 질문의_배분이_닫히면_답은_새_배분에_붙지_않고_실패한다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        try w.ask("r1", "어느 쪽?")
        _ = try w.d.complete(repoID: "r1", summary: "알아서 했다")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "둘", toolUseId: nil)
        w.d.didStop(repoID: "r1", lastMessage: "하나 끝")                // #2 전달
        w.d.didStop(repoID: "r1", lastMessage: "물었다")                 // #2 응답 대기
        let toPane = w.inbox.sent.filter { $0.session == "cc-a" }.count
        #expect(toPane == 2)
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .dispatchClosed(seq: 1))
        let a = try #require(w.d.answers(workspaceID: "w1").first)
        #expect(a.state == .failed && a.failure == Dispatcher.answerDispatchClosed)
        // 그 자리에서 실패한 답은 툴 오류로만 알린다 — relay 를 쓰면 조율자가 같은 실패를 두 번 듣는다(최종 리뷰 1)
        #expect(try w.db.read { try Relay.filter(Column("kind") == RelayKind.answerFailure.rawValue).fetchCount($0) } == 0)
        #expect(try w.db.read { try Relay.filter(Column("kind") == RelayKind.failure.rawValue).fetchCount($0) } == 0)
        let two = try w.db.read { try Dispatch.filter(Column("seq") == 2).fetchOne($0) }
        #expect(two?.state == .waiting)
        #expect(w.inbox.sent.filter { $0.session == "cc-a" }.count == toPane)
        #expect(w.d.initialPrompt(forOrchestrator: "w1")?.contains("답 전달 실패") != true)
        // 실패한 답은 질문을 덮지 않는다 — 다시 불러도 같은 결과
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .dispatchClosed(seq: 1))
    }

    /// 큐에 있던 답이 나중 펌프에서 닫힌 배분을 만나면 relay 로 알린다 — 그때는 툴 응답이 없다.
    @Test func 큐의_답이_나중에_닫힌_배분을_만나면_relay_하나로_알린다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedBusy)   // 배분 #1 턴이 돈다
        _ = try w.d.complete(repoID: "r1", summary: "알아서 했다")        // complete 의 펌프 → 답이 닫힌 #1 을 만난다
        w.d.didStop(repoID: "r1", lastMessage: "끝")
        let a = try #require(w.d.answers(workspaceID: "w1").first)
        #expect(a.state == .failed && a.failure == Dispatcher.answerDispatchClosed)
        let fail = try w.db.read { try Relay.filter(Column("kind") == RelayKind.answerFailure.rawValue).fetchAll($0) }
        #expect(fail.count == 1)
        #expect(fail.first?.body == "배분 #1 이 이미 닫혀 답을 전하지 못했다. 사람에게 알린다. 사람이 '진행' 하면 질문과 답을 instruction 에 넣어 다시 dispatch 한다(원래 배분 종류대로).")
        #expect(try w.db.read { try Relay.filter(Column("kind") == RelayKind.failure.rawValue).fetchCount($0) } == 0)
        #expect(w.inbox.sent.filter { $0.content.contains("조율자 답") }.isEmpty)
        // 조율자가 받는 글 — 배분 #1 자체가 실패한 것처럼 읽히지 않는다
        let toOrch = try #require(w.d.initialPrompt(forOrchestrator: "w1"))
        #expect(toOrch.contains("[두레] ‹android› 답 전달 실패 (배분 #1, "))
        #expect(!toOrch.contains("배분 #1 실패") && !toOrch.contains("배분 #0"))
    }

    @Test func 소켓_실패가_반복되면_실패로_닫고_다음으로_넘어간다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        w.inbox.failNext = 3
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .deliveryFailed(attempts: 1))
        w.busy("r1")                                                   // 배분만 큐에 넣는다(시도 없이)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "다음", toolUseId: nil) == .queuedBusy(seq: 1))
        w.idle("r1", session: "cc-a")
        w.d.retryPending()          // 2회
        #expect(w.inbox.sent.isEmpty)   // 답이 먼저다 — 배분이 앞지르지 않는다
        w.d.retryPending()          // 3회 → 포기, 다음 것(배분 #1)으로
        let a = try #require(w.d.answers(workspaceID: "w1").first)
        #expect(a.state == .failed && a.attempts == 3)
        let fail = try w.db.read { try Relay.filter(Column("kind") == RelayKind.answerFailure.rawValue).fetchAll($0) }
        #expect(fail.count == 1 && fail[0].body.contains("3번") && fail[0].dispatchId == nil)
        let toOrch = try #require(w.d.initialPrompt(forOrchestrator: "w1"))
        #expect(toOrch.contains("[두레] ‹android› 답 전달 실패 ("))     // 배분 밖 답
        #expect(!toOrch.contains("배분 #0"))
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.hasPrefix("[두레] 조율자 배분 #1"))
        w.d.retryPending()          // 더 밀 것이 없다
        #expect(w.inbox.sent.count == 1)
    }

    @Test func retryPending_은_시도한_답이_있는_레포를_민다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        w.inbox.failNext = 1
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .deliveryFailed(attempts: 1))
        #expect(w.inbox.sent.isEmpty)
        w.d.retryPending()
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.hasPrefix("[두레] 조율자 답"))
        #expect(w.d.answers(workspaceID: "w1").first?.state == .delivered)
    }

    @Test func 페인이_안_떠_있으면_argv_로_싣지_않는다() throws {
        let w = try World()
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedNotStarted)
        #expect(w.d.initialPrompt(forRepo: "r1")?.contains("조율자 답") != true)
        w.idle("r1", session: "cc-new")
        w.d.didStart(repoID: "r1", session: "cc-new", source: "startup")
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].session == "cc-new")
        #expect(w.inbox.sent.first?.content.hasPrefix("[두레] 조율자 답 (배분 없음)\n질문: 어느 쪽?\n왼쪽") == true)
    }

    /// 지금 정한 동작(Task 3 리뷰): 큐에 배분도 있으면 argv 로는 배분이 먼저 실리고, 답은 그 배분의 첫 Stop 뒤에 간다.
    @Test func 페인이_안_떠_있으면_argv_배분이_먼저고_답은_첫_Stop_뒤에_간다() throws {
        let w = try World()
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedNotStarted)
        #expect(try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "첫", toolUseId: nil) == .queuedNotStarted(seq: 1))
        let prompt = try #require(w.d.initialPrompt(forRepo: "r1"))
        #expect(prompt.contains("배분 #1 — android\n첫") && !prompt.contains("조율자 답"))
        w.idle("r1", session: "cc-new")
        w.d.didStart(repoID: "r1", session: "cc-new", source: "startup")
        #expect(w.inbox.sent.isEmpty)                                   // argv 첫 턴이 돈다
        w.d.didStop(repoID: "r1", lastMessage: "물었다")                 // 배분 #1 응답 대기
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].session == "cc-new")
        #expect(w.inbox.sent.first?.content.hasPrefix("[두레] 조율자 답 (배분 없음)\n질문: 어느 쪽?\n왼쪽") == true)
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .waiting)   // 배분 밖 답은 되돌리지 않는다
    }

    @Test func 큐의_답_둘은_한_턴에_하나씩_간다() throws {
        let w = try World(); w.busy("r1")
        try w.ask("r1", "첫 질문")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "첫 답") == .queuedBusy)
        try w.ask("r1", "둘째 질문")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "둘째 답") == .queuedBusy)
        w.idle("r1", session: "cc-a")
        w.d.didStop(repoID: "r1", lastMessage: "x")                     // Stop #1
        #expect(w.inbox.sent.count == 1 && w.inbox.sent[0].content.contains("질문: 첫 질문\n첫 답"))
        w.d.didStop(repoID: "r1", lastMessage: "y")                     // Stop #2
        #expect(w.inbox.sent.count == 2 && w.inbox.sent[1].content.contains("질문: 둘째 질문\n둘째 답"))
        w.d.didStop(repoID: "r1", lastMessage: "z")
        #expect(w.inbox.sent.count == 2)
        #expect(w.d.answers(workspaceID: "w1").allSatisfy { $0.state == .delivered })
    }

    /// 닫힌 배분에 묶인 답이 실패로 닫히면 같은 펌프에서 다음 답으로 넘어간다.
    /// `didDie` 는 펌프하지 않으므로 두 답이 한 펌프(둘째 `answer`)에서 만난다.
    @Test func 닫힌_배분의_답이_실패하면_같은_펌프에서_다음_답으로_넘어간다() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        _ = try w.d.enqueue(workspaceID: "w1", repo: w.repoA, title: nil, instruction: "하나", toolUseId: nil)
        try w.ask("r1", "배분 안의 질문")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "첫 답") == .queuedBusy)
        w.d.didDie(repoID: "r1")                                         // 배분 #1 실패로 닫힘, 펌프 없음
        w.idle("r1", session: "cc-b")
        try w.ask("r1", "배분 밖 질문")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "둘째 답") == .delivered)
        let sentToPane = w.inbox.sent.filter { $0.session == "cc-b" }
        #expect(sentToPane.count == 1 && sentToPane[0].content.hasPrefix("[두레] 조율자 답 (배분 없음)\n질문: 배분 밖 질문\n둘째 답"))
        let rows = w.d.answers(workspaceID: "w1")                        // 최신이 먼저
        #expect(rows.map(\.state) == [.delivered, .failed])
        #expect(rows.last?.failure == Dispatcher.answerDispatchClosed)
        #expect(try w.db.read { try Relay.filter(Column("kind") == RelayKind.answerFailure.rawValue).fetchCount($0) } == 1)
    }

    @Test func 답할_질문이_없으면_noQuestion() throws {
        let w = try World(); w.idle("r1", session: "cc-a")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .noQuestion)
        #expect(w.d.answers(workspaceID: "w1").isEmpty)
        #expect(w.inbox.sent.isEmpty)
    }

    /// 카드는 이력을 뒤집어 오래된 것부터 그린다(최종 리뷰 4) — 같은 초의 relay 도 들어온 순서의 반대(최신이 먼저)여야 한다.
    @Test func relay_이력은_같은_초면_나중_것이_먼저다() throws {
        let w = try World()
        for i in 1...5 {
            try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .report, body: "\(i)")
        }
        #expect(w.d.relays(workspaceID: "w1").map(\.body) == ["5", "4", "3", "2", "1"])
    }

    /// 미답 질문은 없지만 보낼 답이 큐에 있다 — `noQuestion`("dispatch 를 쓴다") 이 아니라 `answerPending`. 아무것도 쓰지 않는다(최종 리뷰 2).
    @Test func 보낼_답이_큐에_있으면_answerPending() throws {
        let w = try World(); w.busy("r1")
        try w.ask("r1", "어느 쪽?")
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "왼쪽") == .queuedBusy)
        #expect(try w.d.answer(workspaceID: "w1", repo: w.repoA, body: "오른쪽") == .answerPending)
        let rows = w.d.answers(workspaceID: "w1")
        #expect(rows.count == 1 && rows[0].body == "왼쪽" && rows[0].state == .queued)
        #expect(w.inbox.sent.isEmpty)
    }
}
