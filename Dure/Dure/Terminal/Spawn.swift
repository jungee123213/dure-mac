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
    /// F3 — `--settings` 로 훅을 이 세션에만 얹는다 (DECISIONS.md D-1).
    /// 사용자의 `~/.claude/settings.json` 은 읽지도 쓰지도 않는다.
    static func script(repoPath: String,
                       sessionID: String,
                       model: String?,
                       kind: AgentKind = .claude) -> String {
        var parts = [
            "export DURE_SESSION=\(quoted(sessionID))",
            "export DURE_AGENT_KIND=\(quoted(kind.rawValue))",
            "cd \(quoted(repoPath))"
        ]
        parts.append("exec " + agentCommand(kind: kind, model: model))
        return parts.joined(separator: "; ")
    }

    /// 에이전트별 실행 명령. D-3 — Codex 는 자리만 열어두고 1차에서는 쓰지 않는다.
    private static func agentCommand(kind: AgentKind, model: String?) -> String {
        switch kind {
        case .claude:
            var cmd = "claude --settings \(quoted(HookBridge.settingsURL.path))"
            if let model, !model.isEmpty {
                cmd += " --model \(quoted(model))"
            }
            return cmd
        case .codex:
            // Codex 는 세션 단위 훅 주입이 없다. `~/.codex/` 전역 설정을 써야 하며
            // 그때는 이어붙이기·제거 기계장치가 필요하다 (DECISIONS.md D-3).
            // 실측 전까지 구현하지 않는다.
            return "codex"
        }
    }

    /// 작은따옴표로 감싸고 내부의 작은따옴표를 이스케이프한다.
    /// 레포 경로에 공백·따옴표가 있어도 안전하다.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
