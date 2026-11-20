import Foundation

/// 페인 종류. 조율자는 사용자 규칙을 가져오지 않는다.
enum CodexProfile: String {
    case repoPane, orchestrator
}

/// 페인마다 따로 만드는 `CODEX_HOME`. 규칙은 세션 단위로만 줄 수 있어서 홈을 통째로 만든다.
/// 사용자의 실제 `~/.codex` 에는 아무것도 쓰지 않는다.
enum CodexHome {
    /// 서버가 스스로 만드는 폴더 — 링크하면 서버가 뜨지 않는다(실측).
    private nonisolated static let serverOwned: Set<String> = ["app-server-control", "app-server-daemon", "ipc"]

    nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dure/codex-home")
    }

    /// 서버가 rollout 경로를 이 홈 아래로 기록하므로 키마다 고정 경로여야 하고 페인이 끝나도 지우지 않는다.
    nonisolated static func url(forPaneKey key: String, root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(key.replacingOccurrences(of: ":", with: "-"))
    }

    nonisolated static func prepare(profile: CodexProfile, cwd: String, userHome: URL, into dir: URL) throws {
        let fm = FileManager.default
        remove(dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // config.toml — 링크가 아니라 사본. 링크면 Codex 가 쓰는 신뢰가 전역 파일에 들어간다.
        var text = (try? String(contentsOf: userHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let escaped = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let header = "[projects.\"\(escaped)\"]"
        let hasHeader = text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == header }
        if !hasHeader {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\(header)\ntrust_level = \"trusted\"\n"
        }
        try text.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        // rules/ — 실제 폴더. 레포 페인만 사용자 규칙 사본.
        let rules = dir.appendingPathComponent("rules")
        try fm.createDirectory(at: rules, withIntermediateDirectories: true)
        if profile == .repoPane {
            let src = userHome.appendingPathComponent("rules")
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where name.hasSuffix(".rules") {
                try fm.copyItem(at: src.appendingPathComponent(name), to: rules.appendingPathComponent(name))
            }
        }

        // 나머지 최상위 항목은 사용자 home 으로 링크. hooks.json 은 만들지 않는다.
        let skip = Set(["config.toml", "rules", "hooks.json"]).union(serverOwned)
        for name in (try? fm.contentsOfDirectory(atPath: userHome.path)) ?? [] where !skip.contains(name) {
            try fm.createSymbolicLink(at: dir.appendingPathComponent(name),
                                      withDestinationURL: userHome.appendingPathComponent(name))
        }
    }

    /// 링크는 따라가지 않고 링크 자체만 지운다(FileManager.removeItem 동작).
    nonisolated static func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
