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
}
