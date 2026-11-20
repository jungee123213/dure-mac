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

    /// 다시 맞출 때 지우는 것 — 두레가 만든 것(링크 · config 사본 · rules)과 서버가 매번 새로 만드는 폴더.
    /// hooks.json 은 두레가 만들지 않지만 있으면 사본 home 에서 훅이 돌므로 지운다.
    private nonisolated static let rebuilt: Set<String> = ["config.toml", "rules", "hooks.json"]

    /// 시작할 때마다 다시 맞춘다. **폴더를 통째로 지우지 않는다** — 사용자 home 에 없던 이름(`sessions/` · 새 `state_N.sqlite`)은
    /// 서버가 이 home 안에 실제 파일로 만들고, 그것이 기록이다. 링크 · 두레가 만든 것 · 서버 제어 폴더만 지우고
    /// 나머지 실제 항목은 그대로 두며 그 이름은 링크하지 않는다.
    nonisolated static func prepare(profile: CodexProfile, cwd: String, userHome: URL, into dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let entry = dir.appendingPathComponent(name)
            if isSymlink(entry) || rebuilt.contains(name) || serverOwned.contains(name) {
                try fm.removeItem(at: entry)
            }
        }

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
                // 내용을 복사한다(링크를 따라간다). copyItem 은 링크를 링크로 복사해 "다시 묻지 않기" 가 전역 규칙에 쓰인다.
                guard let data = try? Data(contentsOf: src.appendingPathComponent(name)) else {
                    NSLog("[Dure] Codex home: 규칙 파일을 읽지 못해 건너뜁니다 — \(name)")
                    continue
                }
                try data.write(to: rules.appendingPathComponent(name))
            }
        }

        // 나머지 최상위 항목은 사용자 home 으로 링크. hooks.json 은 만들지 않는다.
        let skip = Set(["config.toml", "rules", "hooks.json"]).union(serverOwned)
        for name in (try? fm.contentsOfDirectory(atPath: userHome.path)) ?? [] where !skip.contains(name) {
            let link = dir.appendingPathComponent(name)
            if exists(link) {
                NSLog("[Dure] Codex home \(dir.lastPathComponent): 실제 항목 \(name) 이 있어 링크하지 않고 그대로 둡니다")
                continue
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: userHome.appendingPathComponent(name))
        }
    }

    private nonisolated static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// 링크를 따라가지 않는 존재 확인(lstat).
    private nonisolated static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// 링크는 따라가지 않고 링크 자체만 지운다(FileManager.removeItem 동작).
    nonisolated static func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
