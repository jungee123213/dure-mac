import Foundation

/// Codex 페인의 서버 · TUI 기동 스크립트와 경로 · 버전 판정. 순수 문자열 조립이라 격리하지 않는다.
///
/// 서버(`codex app-server`)는 두레가 백그라운드 `Process`(`zsh -ilc`)로 직접 띄우고,
/// TUI 는 PTY 에서 소켓이 생길 때까지 기다렸다가 `codex --remote` 로 붙는다.
/// 세션 단위 훅 주입은 서버의 `-c hooks.*` 로 한다(D-44).
nonisolated enum CodexLaunch {

    static let minimumVersion = "0.167.0"

    /// `codex --version` 출력(`codex-cli 0.167.0`)이 최소 버전 이상인가. 못 읽으면 false.
    static func isSupported(versionOutput: String) -> Bool {
        guard let token = versionOutput.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.first?.isNumber == true }) else { return false }
        let have = token.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        let need = minimumVersion.split(separator: ".").compactMap { Int($0) }
        guard have.count >= 3, !have.contains(where: { $0 == nil }) else { return false }
        for (h, n) in zip(have.compactMap { $0 }, need) where h != n { return h > n }
        return true
    }

    // MARK: - 경로

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dure/codex")
    }

    /// 유닉스 소켓 경로는 104바이트 미만이어야 한다. 세션 ID 를 짧게 유지할 것.
    static func socketPath(forSession id: String, root: URL = defaultRoot) -> String {
        root.appendingPathComponent(id + ".sock").path
    }

    static func failMarkerPath(forSession id: String, root: URL = defaultRoot) -> String {
        root.appendingPathComponent(id + ".fail").path
    }

    static func logPath(forSession id: String, root: URL = defaultRoot) -> String {
        root.appendingPathComponent(id + ".log").path
    }

    // MARK: - 스크립트

    private static func exports(_ sessionID: String) -> [String] {
        ["export DURE_SESSION=\(Spawn.quoted(sessionID))",
         "export DURE_AGENT_KIND=\(Spawn.quoted("codex"))"]
    }

    /// 서버 스크립트. 인자마다 `Spawn.quoted`. `cd … && exec` 는 `&&` 로 잇는다(이슈 #10).
    static func serverScript(cwd: String, sessionID: String, home: String, socket: String,
                             hookArguments: [String], disabledPlugins: [String],
                             mcpSocket: String? = nil) -> String {
        // 플래그(`-c` · `--listen`)는 그대로, 값만 인용한다. hookArguments 는 `-c` 와 값이 번갈아 온다.
        var parts = ["app-server", "--listen", Spawn.quoted("unix://" + socket)]
        let configs = ["check_for_update_on_startup=false",
                       "project_doc_fallback_filenames=[\"CLAUDE.md\"]",
                       "features.apps=false"]
            + stride(from: 1, to: hookArguments.count, by: 2).map { hookArguments[$0] }
            + disabledPlugins.map { "plugins.\($0).enabled=false" }
        // 두레 MCP — Codex 는 유닉스 소켓을 못 붙으므로 `nc -U` 를 stdio 서버로 쓴다(승인 창 없이).
        var mcp: [String] = []
        if let mcpSocket {
            mcp = ["mcp_servers.dure.command=\"/usr/bin/nc\"",
                   "mcp_servers.dure.args=[\"-U\",\(CodexHooks.tomlString(mcpSocket))]",
                   "mcp_servers.dure.default_tools_approval_mode=\"approve\""]
        }
        for c in configs + mcp { parts += ["-c", Spawn.quoted(c)] }
        let launch = "cd \(Spawn.quoted(cwd)) && exec codex " + parts.joined(separator: " ")
        return (exports(sessionID) + ["export CODEX_HOME=\(Spawn.quoted(home))", launch]).joined(separator: "; ")
    }

    /// TUI 가 소켓을 기다리는 안전 상한(초). **10초 판정은 런타임이 한다** — 서버를 띄운 때부터 10초 안에 소켓이 없으면
    /// 실패 표식을 쓰고, TUI 는 그 표식을 찍고 끝난다. TUI 의 시계는 PTY 시작부터라 서버 앞 단계(`codex --version` ·
    /// home 준비 · 훅 목록)까지 세므로 10초로 두면 멀쩡한 서버를 두고 페인이 죽는다. 이 상한은 런타임이 표식을
    /// 못 쓰는 경우(앱이 죽음 등)에만 걸린다 — 런타임의 최악 시간보다 길어야 한다(테스트가 고정).
    static let tuiWaitSeconds = 45

    /// TUI 스크립트. 실패 표식이 있으면 그 내용을 찍고, 상한 안에 소켓이 안 생기면 로그 위치를 알리고 끝낸다.
    static func tuiScript(cwd: String, sessionID: String, socket: String, failMarker: String, log: String,
                          profile: CodexProfile, initialPrompt: String?) -> String {
        let sandbox = profile == .orchestrator ? "read-only" : "workspace-write"
        let timeout = "Codex 서버가 \(tuiWaitSeconds)초 안에 뜨지 않았습니다 — 로그: \(log)"
        let wait = "i=0; while [ $i -lt \(tuiWaitSeconds * 10) ]; do "
            + "if [ -e \(Spawn.quoted(failMarker)) ]; then cat \(Spawn.quoted(failMarker)); exit 1; fi; "
            + "if [ -S \(Spawn.quoted(socket)) ]; then break; fi; "
            + "sleep 0.1; i=$((i+1)); done; "
            + "if [ ! -S \(Spawn.quoted(socket)) ]; then printf '%s\\n' \(Spawn.quoted(timeout)); exit 1; fi"
        var cmd = "exec codex --remote \(Spawn.quoted("unix://" + socket)) -C \(Spawn.quoted(cwd))"
            + " -s \(Spawn.quoted(sandbox)) -a \(Spawn.quoted("on-request"))"
            + " -c \(Spawn.quoted("check_for_update_on_startup=false"))"
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            cmd += " -- " + Spawn.quoted(prompt)
        }
        let launch = "cd \(Spawn.quoted(cwd)) && { \(wait); } && \(cmd)"
        return (exports(sessionID) + [launch]).joined(separator: "; ")
    }
}
