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
    /// `VAR=x zsh ...` 접두 형태는 변수가 zsh 에만 붙고 claude 로 전달되지 않는다.
    static func script(repoPath: String, sessionID: String, model: String?) -> String {
        var parts = [
            "export DURE_SESSION=\(quoted(sessionID))",
            "cd \(quoted(repoPath))"
        ]
        if let model, !model.isEmpty {
            parts.append("exec claude --model \(quoted(model))")
        } else {
            parts.append("exec claude")
        }
        return parts.joined(separator: "; ")
    }

    /// 작은따옴표로 감싸고 내부의 작은따옴표를 이스케이프한다.
    /// 레포 경로에 공백·따옴표가 있어도 안전하다.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
