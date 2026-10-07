import Foundation
import Testing
@testable import Dure

/// 이슈 #12 · D-27 — 어느 워크스페이스의 페인을 뷰 트리에 남기는가.
/// **뷰 수명은 유닛 테스트로 못 잡는다.** 그래서 "어느 층을 남기는가" 판단만큼은 여기서 고정한다.
/// 여기가 틀리면 워크스페이스를 바꾸는 순간 돌던 claude 가 조용히 끊긴다.
struct PaneLayoutTests {

    @Test func 선택된_워크스페이스는_시작한_페인이_없어도_그린다() {
        let layers = PaneLayout.layers(workspaceIDs: ["w1"], selected: "w1", startedWorkspaceIDs: [])
        #expect(layers == [.init(workspaceID: "w1", isActive: true)])
    }

    /// **급소.** 이게 빠지면 전환하는 순간 PTY 가 닫힌다.
    @Test func 시작한_페인이_있는_다른_워크스페이스도_숨긴_채_남긴다() {
        let layers = PaneLayout.layers(workspaceIDs: ["w1", "w2"], selected: "w2",
                                       startedWorkspaceIDs: ["w1"])
        #expect(layers.contains(.init(workspaceID: "w1", isActive: false)))
        #expect(layers.contains(.init(workspaceID: "w2", isActive: true)))
    }

    @Test func 시작한_페인이_없는_다른_워크스페이스는_그리지_않는다() {
        let layers = PaneLayout.layers(workspaceIDs: ["w1", "w2"], selected: "w2", startedWorkspaceIDs: [])
        #expect(layers.map(\.workspaceID) == ["w2"])
    }

    /// 층 순서가 선택에 따라 바뀌면 SwiftUI 가 뷰를 옮기며 다시 만들 수 있다. 사이드바 순서로 고정한다.
    @Test func 층_순서는_선택과_무관하게_사이드바_순서다() {
        let ids = ["w1", "w2", "w3"]
        let a = PaneLayout.layers(workspaceIDs: ids, selected: "w1", startedWorkspaceIDs: ["w1", "w2", "w3"])
        let b = PaneLayout.layers(workspaceIDs: ids, selected: "w3", startedWorkspaceIDs: ["w1", "w2", "w3"])
        #expect(a.map(\.workspaceID) == ids)
        #expect(b.map(\.workspaceID) == ids)
    }

    /// 삭제된 워크스페이스의 흔적이 `startedPanes` 에 남아 있어도 층을 만들지 않는다.
    @Test func 목록에_없는_워크스페이스는_무시한다() {
        let layers = PaneLayout.layers(workspaceIDs: ["w1"], selected: "w1", startedWorkspaceIDs: ["gone"])
        #expect(layers.map(\.workspaceID) == ["w1"])
    }

    @Test func 선택이_없으면_시작한_것만_숨겨서_남긴다() {
        let layers = PaneLayout.layers(workspaceIDs: ["w1", "w2"], selected: nil, startedWorkspaceIDs: ["w2"])
        #expect(layers == [.init(workspaceID: "w2", isActive: false)])
    }
}
