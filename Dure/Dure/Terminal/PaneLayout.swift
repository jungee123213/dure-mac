import Foundation

/// 이슈 #12 · D-27 — 워크스페이스를 바꿔도 돌던 페인이 죽지 않게 한다.
///
/// SwiftUI 는 뷰 트리에서 빠진 `NSViewRepresentable` 을 해제하고, SwiftTerm 은 해제될 때
/// PTY 를 닫는다. 그래서 "현재 워크스페이스의 페인만 그린다" 면 전환하는 순간 claude 가 끊기고,
/// 돌아오면 같은 세션ID 로 새 claude 가 뜬다. **시작한 페인이 하나라도 있는 워크스페이스는
/// 화면에 안 보여도 트리에 남긴다.**
///
/// 순수 함수로 뺀 이유 — "어느 층을 남기는가" 가 이 기능의 전부인데 뷰 수명은 유닛 테스트로
/// 못 잡는다. 판단만큼은 테스트로 고정한다.
enum PaneLayout {

    struct Layer: Equatable, Identifiable {
        var workspaceID: String
        /// 지금 보이는 층. 나머지는 투명 + 클릭 차단 + 키 입력 차단.
        var isActive: Bool
        var id: String { workspaceID }
    }

    /// - Parameters:
    ///   - workspaceIDs: 사이드바 순서. **층 순서를 이것으로 고정한다** — 선택에 따라 순서가
    ///     바뀌면 SwiftUI 가 뷰를 옮기며 다시 만들 수 있다.
    ///   - startedWorkspaceIDs: 시작한 페인이 하나라도 있는 워크스페이스.
    static func layers(workspaceIDs: [String], selected: String?,
                       startedWorkspaceIDs: Set<String>) -> [Layer] {
        workspaceIDs.compactMap { id in
            let active = id == selected
            guard active || startedWorkspaceIDs.contains(id) else { return nil }
            return Layer(workspaceID: id, isActive: active)
        }
    }
}
