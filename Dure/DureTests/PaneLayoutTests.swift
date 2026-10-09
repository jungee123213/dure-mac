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

/// 이슈 #20 — 페인 접기. 접힘 집합의 전이만 순수 함수로 고정한다.
/// 뷰 수명(접어도 PTY 가 사는지)은 유닛 테스트로 못 잡고 실물 확인으로 본다.
struct PaneCollapseTests {

    @Test func 하나를_접었다_펴면_원래대로다() {
        let once = PaneLayout.toggled("repo:a", in: [])
        #expect(once == ["repo:a"])
        #expect(PaneLayout.toggled("repo:a", in: once) == [])
    }

    @Test func 다른_페인의_접힘은_건드리지_않는다() {
        #expect(PaneLayout.toggled("repo:b", in: ["repo:a"]) == ["repo:a", "repo:b"])
    }

    /// 사용자 결정 — "레포 전부 접기" 는 조율자를 건드리지 않는다. 사람이 말을 거는 곳은 조율자다.
    @Test func 레포_일괄_토글은_조율자를_건드리지_않는다() {
        let repos = ["repo:a", "repo:b"]
        let folded = PaneLayout.toggledAllRepos(repoKeys: repos, in: ["orch:w"])
        #expect(folded == ["orch:w", "repo:a", "repo:b"])
        let unfolded = PaneLayout.toggledAllRepos(repoKeys: repos, in: folded)
        #expect(unfolded == ["orch:w"])
    }

    /// 하나라도 펼쳐져 있으면 "전부 접기" 다. 섞여 있을 때 일부만 펴는 일이 없어야 한다.
    @Test func 일부만_접혀_있으면_전부_접는다() {
        let repos = ["repo:a", "repo:b", "repo:c"]
        #expect(PaneLayout.toggledAllRepos(repoKeys: repos, in: ["repo:a"]) == ["repo:a", "repo:b", "repo:c"])
        #expect(PaneLayout.allReposCollapsed(repoKeys: repos, collapsed: ["repo:a"]) == false)
        #expect(PaneLayout.allReposCollapsed(repoKeys: repos, collapsed: ["repo:a", "repo:b", "repo:c"]))
    }

    /// 레포가 없으면 "전부 접힘" 이 참이 돼 버튼이 "펼치기" 로 보이면 이상하다. 거짓으로 둔다.
    @Test func 레포가_없으면_전부_접힘이_아니다() {
        #expect(PaneLayout.allReposCollapsed(repoKeys: [], collapsed: []) == false)
        #expect(PaneLayout.toggledAllRepos(repoKeys: [], in: ["orch:w"]) == ["orch:w"])
    }

    /// 전부(조율자 포함) 접히면 빈 공간에 안내를 띄운다. 페인이 하나라도 펼쳐져 있으면 안 띄운다.
    @Test func 전부_접힘_판정() {
        let keys = ["orch:w", "repo:a"]
        #expect(PaneLayout.allCollapsed(keys: keys, collapsed: ["orch:w", "repo:a"]))
        #expect(PaneLayout.allCollapsed(keys: keys, collapsed: ["repo:a"]) == false)
        #expect(PaneLayout.allCollapsed(keys: [], collapsed: []) == false)
    }

    /// 사라진 페인(레포 제거 · 워크스페이스 삭제)의 키가 집합에 남아도 판정에 끼지 않는다.
    @Test func 목록에_없는_키는_무시한다() {
        #expect(PaneLayout.allCollapsed(keys: ["repo:a"], collapsed: ["repo:a", "gone"]))
        #expect(PaneLayout.allReposCollapsed(repoKeys: ["repo:a"], collapsed: ["repo:a", "gone"]))
        // 일괄 토글도 남은 키를 건드리지 않는다 — 전부 접힌 상태에서 펴면 레포 키만 빠진다.
        #expect(PaneLayout.toggledAllRepos(repoKeys: ["repo:a"], in: ["repo:a", "gone"]) == ["gone"])
    }
}
