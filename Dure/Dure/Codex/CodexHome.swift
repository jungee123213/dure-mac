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

    /// 레포 페인 home 의 두레 git 규칙 파일 이름(`CodexGitPolicy.rulesFile()`).
    nonisolated static let dureRulesName = "dure.rules"

    /// 페인에서 고른 "다시 묻지 않기"(이슈 #61). Codex 는 그것을 `rules/default.rules` 에 더하는데 `rules/` 는 시작마다 다시 만든다.
    /// 그래서 다시 만들기 전에 사본에 없던 줄을 home 꼭대기의 이 파일에 모으고, `rules/` 에 같은 이름으로 넣는다.
    /// 레포 페인 home 은 레포마다 하나라 Claude 페인의 레포 `settings.local.json` 처럼 레포마다 쌓인다. 사용자 `~/.codex` 에는 쓰지 않는다.
    nonisolated static let learnedRulesName = "dure-learned.rules"
    /// 지난 준비 때 `rules/default.rules` 에 넣은 사용자 사본. 페인이 더한 줄을 가릴 기준 — 사용자가 그사이 전역에서 지운 줄을 배운 것으로 오인하지 않게.
    private nonisolated static let defaultBaseName = "dure-default-base.rules"
    private nonisolated static let paneDefaultName = "default.rules"

    /// 다시 맞출 때 지우는 것 — 두레가 만든 것(링크 · config 사본 · rules)과 서버가 매번 새로 만드는 폴더.
    /// hooks.json 은 두레가 만들지 않지만 있으면 사본 home 에서 훅이 돌므로 지운다.
    private nonisolated static let rebuilt: Set<String> = ["config.toml", "rules", "hooks.json"]

    /// 시작할 때마다 다시 맞춘다. **폴더를 통째로 지우지 않는다** — 사용자 home 에 없던 이름(`sessions/` · 새 `state_N.sqlite`)은
    /// 서버가 이 home 안에 실제 파일로 만들고, 그것이 기록이다. 링크 · 두레가 만든 것 · 서버 제어 폴더만 지우고
    /// 나머지 실제 항목은 그대로 두며 그 이름은 링크하지 않는다.
    nonisolated static func prepare(profile: CodexProfile, cwd: String, userHome: URL, into dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 지우기 전에 페인이 더한 규칙을 모은다(레포 페인만 — 조율자는 규칙이 없다).
        if profile == .repoPane { try harvestLearned(in: dir, userHome: userHome) }
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

        // rules/ — 실제 폴더. 레포 페인만 사용자 규칙 사본 + 두레 git 규칙(`dure.rules`). 조율자는 비운다.
        let rules = dir.appendingPathComponent("rules")
        try fm.createDirectory(at: rules, withIntermediateDirectories: true)
        if profile == .repoPane {
            let src = userHome.appendingPathComponent("rules")
            for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where name.hasSuffix(".rules") {
                // 같은 이름의 사용자 파일은 가져오지 않는다 — 두레 규칙이 이긴다(아래에서 쓴다).
                if name == dureRulesName || name == learnedRulesName {
                    NSLog("[Dure] Codex home: 사용자 규칙 \(name) 은 두레 규칙과 이름이 같아 가져오지 않습니다")
                    continue
                }
                // 내용을 복사한다(링크를 따라간다). copyItem 은 링크를 링크로 복사해 "다시 묻지 않기" 가 전역 규칙에 쓰인다.
                guard let data = try? Data(contentsOf: src.appendingPathComponent(name)) else {
                    NSLog("[Dure] Codex home: 규칙 파일을 읽지 못해 건너뜁니다 — \(name)")
                    continue
                }
                try data.write(to: rules.appendingPathComponent(name))
            }
            try CodexGitPolicy.rulesFile().write(to: rules.appendingPathComponent(dureRulesName),
                                                 atomically: true, encoding: .utf8)
            // 다음 준비 때 페인이 더한 줄을 가릴 기준 — 방금 넣은 사본 그대로(없으면 빈 파일).
            let base = (try? Data(contentsOf: rules.appendingPathComponent(paneDefaultName))) ?? Data()
            try base.write(to: dir.appendingPathComponent(defaultBaseName))
            let learned = dir.appendingPathComponent(learnedRulesName)
            if let data = try? Data(contentsOf: learned), !data.isEmpty {
                try data.write(to: rules.appendingPathComponent(learnedRulesName))
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

    /// 페인 `rules/default.rules` 에서 지난 사본(`defaultBaseName`)에 없던 줄을 `learnedRulesName` 에 더한다. 같은 줄은 한 번만.
    /// 지난 사본 기록이 없으면(이 기능 전 home) 지금 사용자 `default.rules` 를 기준으로 본다.
    private nonisolated static func harvestLearned(in dir: URL, userHome: URL) throws {
        let paneDefault = dir.appendingPathComponent("rules").appendingPathComponent(paneDefaultName)
        guard !isSymlink(paneDefault), let pane = try? String(contentsOf: paneDefault, encoding: .utf8) else { return }
        let baseText = (try? String(contentsOf: dir.appendingPathComponent(defaultBaseName), encoding: .utf8))
            ?? (try? String(contentsOf: userHome.appendingPathComponent("rules").appendingPathComponent(paneDefaultName),
                            encoding: .utf8)) ?? ""
        let learnedURL = dir.appendingPathComponent(learnedRulesName)
        let learnedText = (try? String(contentsOf: learnedURL, encoding: .utf8)) ?? ""
        func lines(_ t: String) -> [String] {
            t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var known = Set(lines(baseText)).union(lines(learnedText))
        var added: [String] = []
        for line in lines(pane) where !known.contains(line) {
            known.insert(line)
            added.append(line)
        }
        guard !added.isEmpty else { return }
        NSLog("[Dure] Codex home \(dir.lastPathComponent): 페인에서 고른 규칙 \(added.count)줄을 남깁니다")
        let next = lines(learnedText) + added
        try (next.joined(separator: "\n") + "\n").write(to: learnedURL, atomically: true, encoding: .utf8)
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
