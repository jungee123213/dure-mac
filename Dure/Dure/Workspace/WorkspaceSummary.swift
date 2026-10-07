import Foundation

/// 이슈 #12 · D-27 — 안 보이는 워크스페이스에서 돌거나 기다리는 페인을 놓치지 않게 한다.
/// 페인은 전환해도 살아 있지만(Task A), 화면에 안 보이면 승인 대기를 놓친다.
enum WorkspaceSummary {

    struct Counts: Equatable {
        /// claude 가 살아 있는 페인. 대기 중인 것도 포함한다.
        var open = 0
        /// 사람 답을 기다리는 페인.
        var waiting = 0
    }

    /// - Parameter states: 시작한 페인들의 상태. nil 은 막 띄워서 훅이 아직 안 온 것이라 열림으로 센다.
    static func counts(_ states: [AgentState?]) -> Counts {
        var c = Counts()
        for state in states where state != .dead {
            c.open += 1
            if state == .waiting { c.waiting += 1 }
        }
        return c
    }

    /// 사이드바 워크스페이스 목록의 한 줄. 0 인 항목은 생략한다 — 대부분이 0 이라 다 적으면 읽히지 않는다.
    static func label(name: String, _ c: Counts) -> String {
        var parts = [name]
        if c.open > 0 { parts.append("열림 \(c.open)") }
        if c.waiting > 0 { parts.append("대기 \(c.waiting)") }
        return parts.joined(separator: " · ")
    }

    /// 알림 제목. 워크스페이스가 여럿이면 레포 이름만으로는 어디 것인지 모른다.
    static func alertTitle(workspace: String?, repo: String, suffix: String) -> String {
        guard let workspace, !workspace.isEmpty else { return "\(repo) — \(suffix)" }
        return "\(workspace) · \(repo) — \(suffix)"
    }
}
