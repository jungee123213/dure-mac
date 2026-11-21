import Foundation

/// 감시자 폴더. **값으로 넘긴다** — 백그라운드 작업은 MainActor 인 `HookBridge.home` 을 못 읽고, 테스트는 실제 폴더를 쓰면 안 된다.
nonisolated struct ObserverDirs: Sendable {
    var root: URL
    var claudeHome: URL
    var workspacesRoot: URL
    var settingsDir: URL
    /// 사용자 Codex home(`~/.codex`). 두레 Codex 페인 home 의 `sessions` 는 여기 것의 링크라 이것 하나만 읽는다.
    /// nil 이면 Codex 수집을 하지 않는다.
    var codexHome: URL? = nil

    var units: URL { root.appendingPathComponent("units", isDirectory: true) }
    var reference: URL { root.appendingPathComponent("reference", isDirectory: true) }
    var projects: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }
    var chatSettings: URL { settingsDir.appendingPathComponent("observer.json") }
    var codexSessions: URL? { codexHome?.appendingPathComponent("sessions", isDirectory: true) }

    func unitDir(_ id: String) -> URL { units.appendingPathComponent(id, isDirectory: true) }
    /// 실행마다 따로 — 지난 판단의 근거를 덮어쓰지 않는다.
    func runDir(unit: String, run: String) -> URL {
        unitDir(unit).appendingPathComponent("runs", isDirectory: true).appendingPathComponent(run, isDirectory: true)
    }

    func collectExcludes(_ s: ObserverSettings) -> [String] {
        s.excludes + [root.path.hasSuffix("/") ? root.path : root.path + "/"]
    }
}

enum ObserverPaths {
    static var live: ObserverDirs {
        ObserverDirs(root: HookBridge.home.appendingPathComponent("observer", isDirectory: true),
                     claudeHome: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true),
                     workspacesRoot: WorkspaceFolder.defaultRoot,
                     settingsDir: SessionSettings.dir(),
                     // `$CODEX_HOME` 이 아니라 사용자 것 — 두레 페인 home 의 `sessions` 는 이것의 링크다(Codex 1단계).
                     codexHome: CodexPaneRuntime.defaultUserCodexHome)
    }
}
