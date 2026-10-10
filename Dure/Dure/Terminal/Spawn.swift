import Foundation

/// 앱이 터미널을 띄울 때 쓰는 명령 조립. ADR-13 · ADR-14 · v5 실측 반영.
enum Spawn {

    /// ⚠️ `-lc` 가 아니라 `-ilc` 다 (v5 / Step 0-A 실측).
    /// `-lc` 는 로그인이지만 비대화형이라 `.zshrc` 를 읽지 않는다. nvm 이 거기서 PATH 를
    /// 잡는 환경에서는 `claude` 를 못 찾아 exit 127 로 죽는다. 터미널에서 테스트하면
    /// 부모 PATH 에 가려지지만, GUI 앱은 최소 환경만 받으므로 반드시 터진다.
    static let shell = "/bin/zsh"
    static let shellArgs = ["-ilc"]

    /// ADR-14 — 앱이 띄운 세션만 앱의 관할이다. `export` 형태를 반드시 지킨다.
    /// `VAR=x zsh ...` 접두 형태는 변수가 zsh 에만 붙고 에이전트로 전달되지 않는다.
    ///
    /// 하위 에이전트를 출발시키는 **유일한 경로**다 (설계문서 5절). 레포 페인과 조율자가 같이 쓴다.
    /// F3 — `--settings` 로 훅을 이 세션에만 얹는다 (D-1). 전역 `~/.claude/settings.json` 은 건드리지 않는다.
    ///
    /// - `settingsPath` — 페인 종류별 설정 (#16 · `SessionSettings`). 훅 + 권한.
    /// - `sessionName` — `claude --name`. 조율자가 메시지 대상을 고르는 근거 (`SessionName`).
    /// - `addDirs` — 조율자가 읽을 레포들. **가변 인자 옵션이라 프롬프트는 `--` 뒤에 둔다**
    ///   (`--` 없으면 프롬프트를 디렉토리로 삼킨다, 2026-10-07 실측).
    /// - `mcpSocket` — 있으면 두레 MCP 서버를 이 세션에만 붙인다 (`mcpConfig`).
    /// - `extraArgs` — 감시자 묻기 페인의 격리 플래그(`EvalSpec.isolationArgs`). 하나씩 인용한다.
    /// - `initialPrompt` — 첫 프롬프트. D-30 이후 비어 있고 단계 4 에서 쓴다. PTY 에 타이핑하지 않는
    ///   이유는 "언제 다 떴는지" 판단이 곧 화면 파싱이라 ADR-3 에 걸리기 때문이다.
    ///
    /// **모델은 넘기지 않는다** (D-28). 앱이 `--model` 을 넘기면 사람이 고른 것을 덮어쓴다.
    static func script(cwd: String,
                       sessionID: String,
                       settingsPath: String,
                       sessionName: String,
                       addDirs: [String] = [],
                       kind: AgentKind = .claude,
                       initialPrompt: String? = nil,
                       mcpSocket: String? = nil,
                       extraArgs: [String] = []) -> String {
        let exports = [
            "export DURE_SESSION=\(quoted(sessionID))",
            "export DURE_AGENT_KIND=\(quoted(kind.rawValue))"
        ]
        // ⚠️ `cd` 와 `exec` 는 반드시 `&&` 로 잇는다 (이슈 #10).
        // `;` 면 폴더가 없어 `cd` 가 실패해도 에이전트가 앱 프로세스의 cwd 인 `/` 에서 뜬다.
        // 화면상으로는 정상 기동과 구별되지 않는다. `&&` 면 zsh 가 에러를 찍고 끝나 페인이 `종료` 가 된다.
        let launch = "cd \(quoted(cwd)) && exec "
            + agentCommand(kind: kind, settingsPath: settingsPath, sessionName: sessionName,
                           addDirs: addDirs, initialPrompt: initialPrompt, mcpSocket: mcpSocket,
                           extraArgs: extraArgs)
        return (exports + [launch]).joined(separator: "; ")
    }

    /// 단계 4 — `--mcp-config` 인라인 JSON. 세션에만 붙고 승인 프롬프트가 없다(실측). `nc -U` 가 stdio 를 소켓에 잇는다.
    /// `--strict-mcp-config` 는 쓰지 않는다 — 레포 페인은 사용자의 프로젝트 MCP 를 그대로 써야 한다.
    static func mcpConfig(socket: String) -> String {
        let o: [String: Any] = ["mcpServers": [DureTools.serverName: [
            "command": MCPSocketPath.ncPath, "args": ["-U", socket]]]]
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// 에이전트별 실행 명령. D-3 — Codex 는 자리만 열어두고 1차에서는 쓰지 않는다.
    private static func agentCommand(kind: AgentKind, settingsPath: String, sessionName: String,
                                     addDirs: [String], initialPrompt: String?, mcpSocket: String?,
                                     extraArgs: [String]) -> String {
        switch kind {
        case .claude:
            var cmd = "claude --settings \(quoted(settingsPath)) --name \(quoted(sessionName))"
            if let mcpSocket { cmd += " --mcp-config \(quoted(mcpConfig(socket: mcpSocket)))" }
            for a in extraArgs { cmd += " " + quoted(a) }
            for dir in addDirs { cmd += " --add-dir \(quoted(dir))" }
            // 공백뿐인 프롬프트는 없는 것과 같다. 빈 인자를 넘기면 claude 가 빈 프롬프트를 제출한 것으로 받는다.
            if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                cmd += " -- " + quoted(prompt)
            }
            return cmd
        case .codex:
            // Codex 는 세션 단위 훅 주입이 없다. `~/.codex/` 전역 설정을 써야 하며
            // 그때는 이어붙이기·제거 기계장치가 필요하다 (D-3). 실측 전까지 구현하지 않는다.
            return "codex"
        }
    }

    /// 작은따옴표로 감싸고 내부의 작은따옴표를 이스케이프한다.
    /// 레포 경로에 공백·따옴표가 있어도 안전하다.
    /// 감시자(백그라운드)도 쓴다 — 순수 문자열 처리라 격리가 필요 없다.
    nonisolated static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
