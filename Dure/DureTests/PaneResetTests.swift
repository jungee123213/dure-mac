import Foundation
import Testing
@testable import Dure

/// 이슈 #14 — claude 가 끝나면 페인을 시작 대기로 되돌린다.
/// **급소는 "어느 레포를 되돌리는가" 다.** 늦게 도착한 옛 세션의 종료 신호가
/// 새로 시작한 세션을 지우면, 살아 있는 claude 의 페인이 시작 대기로 바뀌어 버린다.
struct PaneResetTests {

    @Test func 지금_세션이_끝나면_그_레포를_되돌린다() {
        let ids = ["r1": "s1", "r2": "s2"]
        #expect(PaneReset.repoToReset(exitedSession: "s2", sessionIDs: ids) == "r2")
    }

    /// 다시 시작해 r1 에 새 세션 s1b 가 걸린 뒤 옛 s1 의 종료가 늦게 왔다.
    @Test func 옛_세션의_종료는_새_세션을_건드리지_않는다() {
        let ids = ["r1": "s1b"]
        #expect(PaneReset.repoToReset(exitedSession: "s1", sessionIDs: ids) == nil)
    }

    @Test func 모르는_세션은_무시한다() {
        #expect(PaneReset.repoToReset(exitedSession: "zzz", sessionIDs: ["r1": "s1"]) == nil)
        #expect(PaneReset.repoToReset(exitedSession: "s1", sessionIDs: [:]) == nil)
    }
}
