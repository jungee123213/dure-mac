import Foundation
import Testing
@testable import Dure

/// Review Focus 1 — 일하는 중에 넣으면 하던 일과 섞인다(D-29 에서 실제로 겪음). 판단을 순수 함수로 못 박는다.
struct DispatchRulesTests {

    @Test(arguments: [AgentState.started, .done])
    func 떠_있고_놀면_전달한다(_ s: AgentState) {
        #expect(DispatchRules.isIdle(started: true, state: s, hasOutstanding: false))
    }

    @Test(arguments: [AgentState.running, .waiting, .dead])
    func 일하는_중이거나_죽었으면_보관한다(_ s: AgentState) {
        #expect(!DispatchRules.isIdle(started: true, state: s, hasOutstanding: false))
    }

    @Test func 안_떴으면_보관한다() {
        #expect(!DispatchRules.isIdle(started: false, state: nil, hasOutstanding: false))
        #expect(!DispatchRules.isIdle(started: true, state: nil, hasOutstanding: false))   // SessionStart 전
    }

    /// 소켓이 시작한 턴에 `UserPromptSubmit` 이 뜨는지 미확인 — 전달 뒤 Stop 까지는 상태와 무관하게 바쁘다.
    @Test func 전달_뒤_Stop_전에는_상태가_done_이어도_바쁘다() {
        #expect(!DispatchRules.isIdle(started: true, state: .done, hasOutstanding: true))
    }

    /// I-1 — 다시 시작한 페인에 옛 세션의 늦은 Stop 이 와도 새 배분을 닫지 않는다.
    @Test func 지금_페인의_세션이_보낸_훅만_받는다() {
        #expect(DispatchRules.acceptsHook(current: .running, sessionOfPane: "s1", eventSession: "s1"))
        #expect(!DispatchRules.acceptsHook(current: .done, sessionOfPane: "s2", eventSession: "s1"))
        #expect(!DispatchRules.acceptsHook(current: .dead, sessionOfPane: "s1", eventSession: "s1"))
        #expect(!DispatchRules.acceptsHook(current: .done, sessionOfPane: nil, eventSession: "s1"))
    }

    /// 이슈 #24 — 열린 배분이 있는 페인에 SessionStart 가 오면. 기동 프롬프트(argv)는 첫 세션이 이어받고,
    /// 같은 세션의 압축 · 재개는 그대로, `/clear` 나 다른 세션이면 그 배분은 끝날 수 없다.
    @Test func 세션_시작_때_열린_배분() {
        #expect(DispatchRules.onSessionStart(deliveredSession: "argv", newSession: "cc", source: "startup") == .adopt)
        #expect(DispatchRules.onSessionStart(deliveredSession: nil, newSession: "cc", source: "startup") == .adopt)
        #expect(DispatchRules.onSessionStart(deliveredSession: "cc-a", newSession: "cc-a", source: "compact") == .keep)
        #expect(DispatchRules.onSessionStart(deliveredSession: "cc-a", newSession: "cc-a", source: "resume") == .keep)
        #expect(DispatchRules.onSessionStart(deliveredSession: "cc-a", newSession: "cc-a", source: "clear") == .fail)
        #expect(DispatchRules.onSessionStart(deliveredSession: "cc-a", newSession: "cc-b", source: "startup") == .fail)
    }

    @Test func 세_번_실패하면_포기한다() {
        #expect(!DispatchRules.givesUp(afterAttempts: 2))
        #expect(DispatchRules.givesUp(afterAttempts: 3))
    }

    @Test(arguments: [("#7", DispatchRules.CancelRef.seq(7)), ("7", .seq(7)), (" #12 ", .seq(12)),
                      ("3F2A-…", .id("3F2A-…")), ("", .id(""))])
    func 취소_인자를_해석한다(_ raw: String, _ ref: DispatchRules.CancelRef) {
        #expect(DispatchRules.cancelRef(raw) == ref)
    }

    @Test func 시각은_시분이다() {
        let s = DispatchRules.clock(0)
        #expect(s.count == 5 && s.contains(":"))
    }
}
