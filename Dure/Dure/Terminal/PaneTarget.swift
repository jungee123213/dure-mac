import Foundation

/// 이슈 #16 — 페인 하나가 무엇을 위한 것인가.
///
/// 레포 페인과 조율자 페인이 **같은 경로**(세션 ID · 시작 여부 · 상태 · 종료 복귀 #14 · 숨긴 층 D-27)를
/// 타게 하려고 둔다. 예전에는 레포 id 를 키로 썼는데 조율자는 레포가 없다.
enum PaneTarget: Hashable, Identifiable {
    case repo(Repo)
    case orchestrator(workspaceID: String)

    /// 상태 사전의 키. 접두사를 붙여 레포 id 와 워크스페이스 id 가 같은 공간에서 부딪히지 않게 한다.
    var key: String {
        switch self {
        case .repo(let r): "repo:\(r.id)"
        case .orchestrator(let w): "orch:\(w)"
        }
    }

    var id: String { key }

    var workspaceID: String {
        switch self {
        case .repo(let r): r.workspaceId
        case .orchestrator(let w): w
        }
    }

    var repo: Repo? {
        if case .repo(let r) = self { return r }
        return nil
    }
}
