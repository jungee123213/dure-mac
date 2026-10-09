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

// MARK: - 이슈 #20 · 페인 접기

/// 접힌 페인은 헤더 한 줄만 남고 펼쳐진 페인끼리 높이를 나눈다. **터미널은 트리에 남긴다** (D-27 과 같은 이유 —
/// 빠지면 PTY 가 닫힌다). 여기는 "무엇이 접혀 있나" 의 전이만 다룬다. 뷰 수명은 실물 확인의 몫이다.
extension PaneLayout {

    static func toggled(_ key: String, in collapsed: Set<String>) -> Set<String> {
        var next = collapsed
        if next.contains(key) { next.remove(key) } else { next.insert(key) }
        return next
    }

    /// "레포 전부 접기" ↔ "전부 펼치기". **조율자는 건드리지 않는다** — 사람이 말을 거는 곳이다.
    /// 하나라도 펼쳐져 있으면 전부 접는다. 섞인 상태에서 일부만 펴면 무엇이 바뀌었는지 알 수 없다.
    static func toggledAllRepos(repoKeys: [String], in collapsed: Set<String>) -> Set<String> {
        var next = collapsed
        if allReposCollapsed(repoKeys: repoKeys, collapsed: collapsed) {
            next.subtract(repoKeys)
        } else {
            next.formUnion(repoKeys)
        }
        return next
    }

    /// 레포가 없으면 거짓 — 그래야 버튼이 "접기" 로 보인다(펼칠 것이 없는데 "펼치기" 면 이상하다).
    static func allReposCollapsed(repoKeys: [String], collapsed: Set<String>) -> Bool {
        !repoKeys.isEmpty && repoKeys.allSatisfy(collapsed.contains)
    }

    /// 조율자까지 전부 접혔다 — 빈 공간에 안내를 띄울 때.
    static func allCollapsed(keys: [String], collapsed: Set<String>) -> Bool {
        !keys.isEmpty && keys.allSatisfy(collapsed.contains)
    }
}
