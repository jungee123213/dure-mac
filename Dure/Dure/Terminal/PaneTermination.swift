import Foundation

/// Codex 페인의 서버가 TUI 보다 먼저 끝났을 때 페인을 닫는 방법.
///
/// 서버가 죽으면 TUI 는 "Reconnecting…" 으로 남는다. `markDead` 로 뷰만 트리에서 빼면 PTY 는 끝나지 않는다.
/// `TerminalPane` 은 걷어낼 때 프로세스를 끄지 않고(층을 바꿔도 페인이 살아 있어야 한다, D-27),
/// SwiftTerm `LocalProcess` 도 deinit 에서 신호를 보내지 않는다. 그래서 보이지 않는 TUI 가 앱 종료까지 남는다.
/// → 스토어가 그 페인의 터미널에 **끝내기를 요청**하고, 터미널이 PTY 를 끝낸 뒤 `onExit` → `markDead` 가 요청을 지운다.
/// Claude 페인에는 이 요청이 생기지 않는다(Codex 서버 종료에서만 부른다).
enum PaneTermination {

    enum Reaction: Equatable {
        /// 옛 세션의 늦은 종료 — 다시 시작한 페인을 건드리지 않는다.
        case ignore
        /// 그 페인의 터미널에 끝내기를 요청한다.
        case endTerminal
        /// 끝낼 터미널이 없다 — 바로 `markDead`.
        case markDead
    }

    static func onServerExit(exitedSession: String, paneSession: String?, terminalLive: Bool) -> Reaction {
        guard paneSession == exitedSession else { return .ignore }
        return terminalLive ? .endTerminal : .markDead
    }

    /// 끝내기를 요청받은 페인 키. 스토어가 관측 값으로 들고, 뷰가 읽어 `TerminalPane.terminateRequested` 로 넘긴다.
    struct Requests: Equatable {
        private(set) var keys: Set<String> = []
        func contains(_ key: String) -> Bool { keys.contains(key) }
        mutating func request(_ key: String) { keys.insert(key) }
        mutating func clear(_ key: String) { keys.remove(key) }
    }

    /// 요청한 터미널이 이만큼 지나도 끝나지 않으면(뷰가 트리에 없었다 등) 스토어가 직접 `markDead` 한다.
    static let fallback: TimeInterval = 3
}
