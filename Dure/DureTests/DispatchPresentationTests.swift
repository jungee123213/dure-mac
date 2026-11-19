import Foundation
import Testing
@testable import Dure

/// 단계 4 — 대시보드 ④ 의 글. 뷰는 테스트하지 않으니 글을 만드는 부분을 순수 함수로 뺀다.
@MainActor
struct DispatchPresentationTests {

    static func d(_ state: DispatchState, title: String? = nil, instruction: String = "로그인 버튼\n둘째 줄",
                  delivered: Int? = nil, done: Int? = nil, failure: String? = nil) -> Dispatch {
        Dispatch(workspaceId: "w", seq: 7, repoId: "r", title: title, instruction: instruction, state: state,
                 toolUseId: nil, deliveredSession: nil, result: nil, failure: failure, createdAt: 0,
                 deliveredAt: delivered, doneAt: done)
    }

    @Test func 상태_라벨() {
        #expect(DispatchPresentation.stateLabel(.queued) == "큐 대기")
        #expect(DispatchPresentation.stateLabel(.delivered) == "전달됨")
        #expect(DispatchPresentation.stateLabel(.done) == "완료")
        #expect(DispatchPresentation.stateLabel(.failed) == "실패")
        #expect(DispatchPresentation.stateLabel(.cancelled) == "취소")
        #expect(DispatchPresentation.stateLabel(.waiting) == "응답 대기")
    }

    @Test func 한_줄은_번호_레포_상태_시각() {
        let line = DispatchPresentation.line(Self.d(.delivered, delivered: 3600 * 2 + 60 * 32), repoName: "android")
        #expect(line.hasPrefix("#7 android · 전달됨 ") && line.hasSuffix(":32"))
        #expect(DispatchPresentation.line(Self.d(.queued), repoName: "a") == "#7 a · 큐 대기")
        #expect(DispatchPresentation.line(Self.d(.failed, failure: "앱 종료"), repoName: "a") == "#7 a · 실패 (앱 종료)")
    }

    @Test func 제목이_없으면_지시문_첫_줄() {
        #expect(DispatchPresentation.headline(Self.d(.queued, title: "제목")) == "제목")
        #expect(DispatchPresentation.headline(Self.d(.queued)) == "로그인 버튼")
        let long = String(repeating: "가", count: 80)
        #expect(DispatchPresentation.headline(Self.d(.queued, instruction: long)).count == 61)   // 60자 + …
    }

    @Test func 시작_대기_안내() {
        #expect(DispatchPresentation.waitingHint(queueCount: 0, firstSeq: nil) == nil)
        #expect(DispatchPresentation.waitingHint(queueCount: 1, firstSeq: 7) == "시작하면 #7 을 싣습니다")
        #expect(DispatchPresentation.waitingHint(queueCount: 3, firstSeq: 7) == "시작하면 #7 을 싣습니다 (대기 3)")
    }

    @Test func 조율자행_라벨() {
        let r = Relay(workspaceId: "w", dispatchId: nil, repoId: nil, kind: .question, body: "b", state: .queued, createdAt: 0, deliveredAt: nil)
        #expect(DispatchPresentation.relayLabel(r) == "질문")
        var f = r; f.kind = .answerFailure
        #expect(DispatchPresentation.relayLabel(f) == "답 전달 실패")
    }

    /// I-3 — 배분 밖의 보고 · 지워진 배분을 가리키는 relay 도 화면에 남는다.
    @Test func relay_를_배분별로_묶고_나머지는_고아로() {
        func r(_ id: String?, _ body: String) -> Relay {
            Relay(workspaceId: "w", dispatchId: id, repoId: "r", kind: .report, body: body, state: .delivered, createdAt: 0, deliveredAt: nil)
        }
        let g = DispatchPresentation.group(relays: [r("d1", "a"), r(nil, "b"), r("d1", "c"), r("gone", "d"), r("d2", "e")],
                                           dispatchIDs: ["d1", "d2"])
        #expect(g.byDispatch["d1"]?.map(\.body) == ["a", "c"])
        #expect(g.byDispatch["d2"]?.map(\.body) == ["e"])
        #expect(g.orphans.map(\.body) == ["b", "d"])
    }

    @Test func git_줄은_종류와_있는_값만() {
        var d = Self.d(.queued)
        #expect(DispatchPresentation.gitLine(d) == nil)
        d.gitMode = .newIssue
        #expect(DispatchPresentation.gitLine(d) == "새 이슈")
        d.issueNumber = 165; d.branch = "x"; d.prNumber = 42
        #expect(DispatchPresentation.gitLine(d) == "새 이슈 · 이슈 #165 · x · PR #42")
        var c = Self.d(.queued)
        c.gitMode = .continueWork; c.issueNumber = 165; c.branch = "feat/#165/x"
        #expect(DispatchPresentation.gitLine(c) == "이어 하기 · 이슈 #165 · feat/#165/x")
        var n = Self.d(.queued)
        n.issueNumber = 3
        #expect(DispatchPresentation.gitLine(n) == "이슈 #3")
    }

    private static func ans(_ id: String, _ dispatch: String?, _ state: AnswerState, failure: String? = nil) -> Answer {
        Answer(id: id, workspaceId: "w", repoId: "r", dispatchId: dispatch, questionId: nil, body: id, state: state,
               failure: failure, attempts: 0, createdAt: 0, deliveredAt: nil)
    }

    @Test func 답_라벨() {
        #expect(DispatchPresentation.answerLabel(Self.ans("a", nil, .queued)) == "답 · 대기")
        #expect(DispatchPresentation.answerLabel(Self.ans("a", nil, .delivered)) == "답")
        #expect(DispatchPresentation.answerLabel(Self.ans("a", nil, .failed, failure: "배분이 닫힘")) == "답 · 실패: 배분이 닫힘")
    }

    @Test func 답_묶음은_카드로_없으면_고아로() {
        let g = DispatchPresentation.group(
            answers: [Self.ans("a", "d1", .delivered), Self.ans("b", nil, .queued), Self.ans("c", "d1", .queued),
                      Self.ans("d", "gone", .delivered)],
            dispatchIDs: ["d1"])
        #expect(g.byDispatch["d1"]?.map(\.id) == ["a", "c"])
        #expect(g.orphans.map(\.id) == ["b", "d"])
    }

    private static func rel(_ id: String, _ kind: RelayKind, at t: Int) -> Relay {
        Relay(id: id, workspaceId: "w", dispatchId: "d1", repoId: "r", kind: kind, body: id, state: .delivered, createdAt: t, deliveredAt: nil)
    }

    private static func ans(_ id: String, at t: Int) -> Answer {
        Answer(id: id, workspaceId: "w", repoId: "r", dispatchId: "d1", questionId: nil, body: id, state: .delivered,
               failure: nil, attempts: 0, createdAt: t, deliveredAt: nil)
    }

    /// 설계 6절 — 카드에서 답은 모든 relay 밑이 아니라 시간순으로 질문 바로 다음에 놓인다(최종 리뷰 4).
    @Test func 카드_줄은_relay_와_답을_시간순으로_섞는다() {
        let rows = DispatchPresentation.cardRows(relays: [Self.rel("q", .question, at: 10), Self.rel("c", .completion, at: 30)],
                                                 answers: [Self.ans("a", at: 20)])
        #expect(rows.map(\.id) == ["r:q", "a:a", "r:c"])
    }

    @Test func 카드_줄은_같은_초면_relay_가_먼저고_각_목록의_순서를_지킨다() {
        let rows = DispatchPresentation.cardRows(relays: [Self.rel("q1", .question, at: 10), Self.rel("q2", .question, at: 10)],
                                                 answers: [Self.ans("a1", at: 10), Self.ans("a2", at: 10)])
        #expect(rows.map(\.id) == ["r:q1", "r:q2", "a:a1", "a:a2"])
        let one = DispatchPresentation.cardRows(relays: [Self.rel("q", .question, at: 10)], answers: [Self.ans("a", at: 10)])
        #expect(one.map(\.id) == ["r:q", "a:a"])
    }
}
