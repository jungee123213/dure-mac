import Foundation
import GRDB
import Testing
@testable import Dure

/// 단계 4 — 툴 호출이 스토어 없이 Dispatcher 와 컨텍스트만으로 답하는지. 스토어는 실제 DB 라 여기서 못 쓴다.
@MainActor
struct DureToolHostTests {

    /// World 를 테스트 인스턴스가 쥔다. Dispatcher 의 lookups 가 World 를 `unowned` 로 잡으므로,
    /// 튜플에서 `_` 로 버리면 World 가 해제돼 첫 조회에서 프로세스가 죽는다(테스트 호스트째로).
    private let held: DispatcherTests.World

    init() throws { held = try DispatcherTests.World() }

    func world() -> (Dispatcher, DureToolHost.Context, DispatcherTests.World) {
        let w = held
        w.idle("r1", session: "cc-a"); w.orchIdle()
        let ctx = DureToolHost.Context(workspaceID: "w1", repos: [w.repoA, w.repoB], repoID: nil,
                                       workspaceMarkdown: { "# 지도\n" }, canStart: { _ in true })
        return (w.d, ctx, w)
    }

    @Test func dispatch_는_레포를_찾아_넘기고_결과를_말한다() throws {
        let (d, ctx, w) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "Android", "instruction": "파랑"], toolUseId: "tu"),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("#1") && r.text.contains("android") && r.text.contains("전달"))
        #expect(w.inbox.sent.count == 1)
    }

    @Test func dispatch_는_안_뜬_페인이면_그렇게_말한다() throws {
        let (d, ctx, _) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "x"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("안 떠") && r.text.contains("시작"))
    }

    /// Review Focus 4.
    @Test func 모르는_레포면_후보를_준다() throws {
        let (d, ctx, w) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "backend", "instruction": "x"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError && r.text.contains("android (/a/android)"))
        #expect(w.d.queueCount(repoID: "r1") == 0 && w.d.history(workspaceID: "w1").isEmpty)
    }

    @Test func 빈_지시문은_거부한다() throws {
        let (d, ctx, _) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "  "], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError)
    }

    @Test func workspace_는_지도에_큐와_상태를_붙인다() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "x"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        let r = DureToolHost.call(.init(name: "workspace", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.text.hasPrefix("# 지도\n") && r.text.contains("## 배분 큐") && r.text.contains("ios") && r.text.contains("1"))
        #expect(r.text.contains("- ios: 대기 1 · 상태 시작 대기"))
        var ctx2 = ctx; ctx2.paneState = { $0 == "r1" ? "실행중" : nil }
        let r2 = DureToolHost.call(.init(name: "workspace", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx2, dispatcher: d)
        #expect(r2.text.contains("- android: 대기 0 · 상태 실행중"))
    }

    /// 최종 리뷰 I-4 — 폴더가 없는 레포는 아무도 시작할 수 없다. 큐에 넣지 않고 바로 알린다.
    @Test func 폴더가_없는_레포에는_배분하지_않는다() throws {
        let (d, ctx0, w) = world()
        var ctx = ctx0; ctx.canStart = { _ in false }
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "x"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError && r.text.contains("폴더가 없어") && r.text.contains("/a/ios"))
        #expect(w.d.history(workspaceID: "w1").isEmpty)
    }

    @Test func tasks_는_최신_30개만_주고_나머지는_개수로() throws {
        let (d, ctx, _) = world()
        for i in 1...31 {
            _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "일 \(i)"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        }
        let lines = DureToolHost.call(.init(name: "tasks", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
            .text.split(separator: "\n").map(String.init)
        #expect(lines.count == 31)
        #expect(lines.first?.hasPrefix("- #31 ") == true && lines[29].hasPrefix("- #2 "))
        #expect(lines.last == "(… 외 1건 — state 로 거르거나 대시보드에서)")
    }

    /// 최종 리뷰 I-3 — 배분을 하던 중의 보고 · 질문은 그 배분 번호를 달고 간다.
    @Test func 보고와_질문은_하던_배분에_묶인다() throws {
        let (d, ctx0, w) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "파랑"], toolUseId: nil),
                              side: .orchestrator, context: ctx0, dispatcher: d)
        let id = try #require(w.d.outstandingDispatchID(repoID: "r1"))
        var ctx = ctx0; ctx.repoID = "r1"
        _ = DureToolHost.call(.init(name: "ask_orchestrator", arguments: ["question": "어느 API?"], toolUseId: nil),
                              side: .repo, context: ctx, dispatcher: d)
        #expect(try w.db.read { try Relay.fetchOne($0) }?.dispatchId == id)
        #expect(w.inbox.sent.last?.session == "cc-orch" && w.inbox.sent.last?.content.contains("‹android› 질문 (배분 #1, ") == true)
    }

    // MARK: - answer (이슈 #43)

    private func answerCall(_ repo: String, _ answer: String) -> MCPToolCall {
        .init(name: "answer", arguments: ["repo": repo, "answer": answer], toolUseId: nil)
    }

    private func askVia(_ repoID: String, _ ctx0: DureToolHost.Context, _ d: Dispatcher) {
        var ctx = ctx0; ctx.repoID = repoID
        _ = DureToolHost.call(.init(name: "ask_orchestrator", arguments: ["question": "어느 쪽?"], toolUseId: nil),
                              side: .repo, context: ctx, dispatcher: d)
    }

    @Test func 질문이_없으면_answer_는_에러고_아무것도_안_쓴다() throws {
        let (d, ctx, w) = world()
        let r = DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError && r.text.contains("dispatch"))
        #expect(d.answers(workspaceID: "w1").isEmpty)
        #expect(w.inbox.sent.isEmpty)
    }

    @Test func answer_는_레포_소켓에서_거부된다() throws {
        let (d, ctx0, _) = world()
        var ctx = ctx0; ctx.repoID = "r1"
        #expect(DureToolHost.call(answerCall("android", "왼쪽"), side: .repo, context: ctx, dispatcher: d).isError)
    }

    @Test func answer_는_없는_레포와_빈_답을_거부한다() throws {
        let (d, ctx, _) = world()
        askVia("r1", ctx, d)
        let bad = DureToolHost.call(answerCall("backend", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(bad.isError && bad.text.contains("android (/a/android)"))
        #expect(DureToolHost.call(answerCall("android", "  "), side: .orchestrator, context: ctx, dispatcher: d).isError)
        #expect(d.answers(workspaceID: "w1").isEmpty)
    }

    @Test func answer_는_페인이_쉬면_전달했다고_말한다() throws {
        let (d, ctx, w) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "파랑"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        d.didStop(repoID: "r1", lastMessage: "조율자에게 물었다")
        askVia("r1", ctx, d)
        let r = DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("전달했다"))
        #expect(w.inbox.sent.last?.content.contains("왼쪽") == true)
    }

    @Test func answer_는_턴_중이면_이_턴이_끝나면_이라고_말한다() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "파랑"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        askVia("r1", ctx, d)
        let r = DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("이 턴이 끝나면"))
    }

    @Test func answer_는_안_뜬_페인이면_사람에게_알리라고_말한다() throws {
        let (d, ctx, _) = world()
        askVia("r2", ctx, d)
        let r = DureToolHost.call(answerCall("ios", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("사람에게 알려라"))
    }

    @Test func answer_는_전달에_실패하면_다시_시도한다고_말한다() throws {
        let (d, ctx, w) = world()
        askVia("r1", ctx, d)
        w.inbox.failNext = 1
        let r = DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("전달 실패(1회)") && r.text.contains("다시 시도"))
    }

    @Test func answer_는_질문의_배분이_닫혔으면_에러로_말한다() throws {
        let (d, ctx, w) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "하나"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        askVia("r1", ctx, d)
        _ = try d.complete(repoID: "r1", summary: "알아서 했다")
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "둘"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        d.didStop(repoID: "r1", lastMessage: "하나 끝")
        d.didStop(repoID: "r1", lastMessage: "물었다")
        let r = DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError)
        #expect(r.text == "배분 #1 이 이미 닫혀 답을 전하지 못했다. 사람에게 알려라. 사람이 '진행' 하면 질문과 답을 instruction 에 넣어 다시 dispatch 한다(원래 배분 종류대로).")
        // 툴 오류로 이미 알렸다 — 같은 실패를 relay 로 또 보내지 않는다(최종 리뷰 1)
        #expect(try w.db.read { try Relay.filter(Column("kind") == RelayKind.answerFailure.rawValue).fetchCount($0) } == 0)
    }

    @Test func answer_는_보낼_답이_큐에_있으면_에러로_말하고_아무것도_안_쓴다() throws {
        let (d, ctx, w) = world()
        w.busy("r1")
        askVia("r1", ctx, d)
        #expect(!DureToolHost.call(answerCall("android", "왼쪽"), side: .orchestrator, context: ctx, dispatcher: d).isError)
        let r = DureToolHost.call(answerCall("android", "오른쪽"), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError)
        #expect(r.text == "이미 보낼 답이 큐에 있다(아직 안 감). 고치려면 사람이 그 페인 터미널에서 직접 답한다.")
        #expect(d.answers(workspaceID: "w1").map(\.body) == ["왼쪽"])
    }

    @Test func ask_orchestrator_응답은_조율자가_사람_승인을_받아_답한다고_말한다() throws {
        let (d, ctx0, _) = world()
        var ctx = ctx0; ctx.repoID = "r1"
        let r = DureToolHost.call(.init(name: "ask_orchestrator", arguments: ["question": "어느 API?"], toolUseId: nil),
                                  side: .repo, context: ctx, dispatcher: d)
        #expect(r.text.contains("조율자가 사람 승인을 받아 답한다"))
    }

    @Test func tasks_는_이력을_상태로_거른다() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "a"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "b"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        let all = DureToolHost.call(.init(name: "tasks", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(all.text.contains("#1") && all.text.contains("#2"))
        let queued = DureToolHost.call(.init(name: "tasks", arguments: ["state": "queued"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(queued.text.contains("#2") && !queued.text.contains("#1"))
        #expect(DureToolHost.call(.init(name: "tasks", arguments: ["state": "weird"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d).isError)
    }

    @Test func cancel_은_번호로() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "b"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!DureToolHost.call(.init(name: "cancel", arguments: ["id": "#1"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d).isError)
        #expect(DureToolHost.call(.init(name: "cancel", arguments: ["id": "#1"], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d).isError)
    }

    @Test func 레포_페인은_보고와_질문만_되고_조율자_툴은_안_된다() throws {
        let (d, ctx0, w) = world()
        var ctx = ctx0; ctx.repoID = "r1"
        let r = DureToolHost.call(.init(name: "ask_orchestrator", arguments: ["question": "어느 API?"], toolUseId: nil), side: .repo, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("전달"))
        #expect(w.inbox.sent.last?.session == "cc-orch" && w.inbox.sent.last?.content.contains("‹android› 질문") == true)
        d.didStopOrchestrator(workspaceID: "w1")   // 조율자가 질문을 읽은 턴이 끝나야 다음 것이 간다(I-2)
        _ = DureToolHost.call(.init(name: "report", arguments: ["summary": "절반"], toolUseId: nil), side: .repo, context: ctx, dispatcher: d)
        #expect(w.inbox.sent.last?.content.contains("‹android› 보고") == true)
        #expect(DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "x"], toolUseId: nil), side: .repo, context: ctx, dispatcher: d).isError)
    }

    /// 이슈 #24 — 레포 페인이 complete 로 배분을 닫는다. 열린 배분이 없으면 에러.
    @Test func complete_는_하던_배분을_닫는다() throws {
        let (d, ctx0, w) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "파랑"], toolUseId: nil),
                              side: .orchestrator, context: ctx0, dispatcher: d)
        var ctx = ctx0; ctx.repoID = "r1"
        let r = DureToolHost.call(.init(name: "complete", arguments: ["summary": "파랑으로 바꿨다"], toolUseId: nil),
                                  side: .repo, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("#1"))
        #expect(try w.db.read { try Dispatch.fetchOne($0) }?.state == .done)
        #expect(w.inbox.sent.last?.content.contains("‹android› 배분 #1 끝남") == true)
        #expect(DureToolHost.call(.init(name: "complete", arguments: ["summary": "또"], toolUseId: nil),
                                  side: .repo, context: ctx, dispatcher: d).isError)
        #expect(DureToolHost.call(.init(name: "complete", arguments: ["summary": " "], toolUseId: nil),
                                  side: .repo, context: ctx, dispatcher: d).isError)
    }

    @Test func tasks_는_응답_대기를_보여준다() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "a"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        d.didStop(repoID: "r1", lastMessage: "A 로 할까요?")
        let r = DureToolHost.call(.init(name: "tasks", arguments: ["state": "waiting"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.text.contains("#1") && r.text.contains("응답 대기") && r.text.contains("A 로 할까요?"))
    }

    @Test func dispatch_는_새_이슈_칸을_저장한다() throws {
        let (d, ctx, w) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                                  "issue_title": "[FEAT] 공유", "issue_body": "본문"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError)
        #expect(d.history(workspaceID: "w1").first?.gitMode == .newIssue)
        _ = w
    }

    /// 최종 리뷰 — 조율자가 고른 배분 종류가 실제로 그렇게 들어갔는지 답에서 보인다(칸을 빠뜨리면 git 없음으로 떨어진다).
    @Test func dispatch_답에_배분_종류가_보인다() throws {
        let (d, ctx, w) = world()
        let n = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                                  "issue_title": "t", "issue_body": "b"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!n.isError && n.text.contains("새 이슈"), "\(n.text)")
        let c = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "ios", "instruction": "x",
                                  "issue": "165", "branch": "feat/#165/x"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!c.isError && c.text.contains("이어 하기"), "\(c.text)")
        let g = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "y"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!g.isError && g.text.contains("git 없음"), "\(g.text)")
        _ = w
    }

    @Test func dispatch_는_제목_없는_이슈_본문을_거절한다() throws {
        let (d, ctx, _) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                                  "issue_body": "본문"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError && r.text.contains(DispatchGitError.bodyWithoutTitle.message))
        #expect(d.history(workspaceID: "w1").isEmpty)
    }

    @Test func dispatch_는_잘못된_git_칸을_거절하고_기록하지_않는다() throws {
        let (d, ctx, _) = world()
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                                  "issue_title": "[FEAT] 공유"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.isError && r.text.contains(DispatchGitError.emptyBody.message))
        #expect(d.history(workspaceID: "w1").isEmpty)
    }

    @Test func complete_는_번호와_브랜치를_저장한다() throws {
        let (d, ctx0, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                              "issue_title": "t", "issue_body": "b"], toolUseId: nil),
                              side: .orchestrator, context: ctx0, dispatcher: d)
        var ctx = ctx0; ctx.repoID = "r1"
        let r = DureToolHost.call(.init(name: "complete", arguments: ["summary": "끝", "issue": "#165",
                                  "branch": "feat/#165/x", "pr": "https://github.com/o/r/pull/42"], toolUseId: nil),
                                  side: .repo, context: ctx, dispatcher: d)
        #expect(!r.isError)
        let row = d.history(workspaceID: "w1").first
        #expect(row?.issueNumber == 165 && row?.branch == "feat/#165/x" && row?.prNumber == 42)
    }

    @Test func tasks_줄에_git_줄이_붙는다() throws {
        let (d, ctx, _) = world()
        _ = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x",
                              "issue": "165", "branch": "feat/#165/x"], toolUseId: nil),
                              side: .orchestrator, context: ctx, dispatcher: d)
        let r = DureToolHost.call(.init(name: "tasks", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d)
        #expect(r.text.contains("이어 하기 · 이슈 #165"))
    }

    @Test func 모르는_툴은_에러() throws {
        let (d, ctx, _) = world()
        #expect(DureToolHost.call(.init(name: "nope", arguments: [:], toolUseId: nil), side: .orchestrator, context: ctx, dispatcher: d).isError)
    }

    // MARK: - Codex 한도 (4단계 Task 4)

    @Test func dispatch_는_Codex_한도로_대기면_그렇게_말한다() throws {
        let (d, ctx, w) = world()
        w.repoPanes["r1"] = .init(started: true, state: .done, address: .codex(socket: "/s", thread: "T"),
                                  kind: .codex, limitedUntil: 5000)
        let r = DureToolHost.call(.init(name: "dispatch", arguments: ["repo": "android", "instruction": "x"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("#1") && r.text.contains("Codex 한도로 대기"))
        #expect(r.text.contains(DispatchBody.hourMinute(5000)) && r.text.contains("이후 저절로 간다"))
        #expect(w.inbox.sent.isEmpty)
    }

    @Test func answer_는_Codex_한도로_대기면_그렇게_말한다() throws {
        let (d, ctx, w) = world()
        try w.d.relay(workspaceID: "w1", dispatchID: nil, repoID: "r1", kind: .question, body: "어느 쪽?")
        w.repoPanes["r1"] = .init(started: true, state: .done, address: .codex(socket: "/s", thread: "T"),
                                  kind: .codex, limitedUntil: 5000)
        let r = DureToolHost.call(.init(name: "answer", arguments: ["repo": "android", "answer": "왼쪽"], toolUseId: nil),
                                  side: .orchestrator, context: ctx, dispatcher: d)
        #expect(!r.isError && r.text.contains("Codex 한도로 대기") && r.text.contains("이후 저절로 간다"))
    }
}
