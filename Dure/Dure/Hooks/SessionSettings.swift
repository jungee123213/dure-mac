import Foundation

/// 이슈 #16 · D-31 — 페인 종류별 `claude --settings` 파일.
///
/// `--settings` 는 파일 하나만 받는다. 그래서 훅(F3)과 권한을 한 파일에 합친다.
/// - 레포 페인: 훅 + `SendMessage`·`ListAgents` 거부. D-29 처럼 레포 에이전트가 맥 전체 세션에
///   메시지를 뿌리는 것을 막는다.
/// - 조율자: 훅 + 레포 절대경로별 git **읽기** 허용. 조율자 cwd 는 워크스페이스 폴더라 레포 git 은
///   `git -C <경로> …` 로 읽는다. `git -C:*` 는 commit·push 까지 열고(ADR-4), `git -C * log *` 는
///   `-c` 옵션 끼워 넣기에 열린다(Claude Code 자체 경고). 경로를 박은 규칙만 쓴다.
///
/// **조율자 설정은 워크스페이스 폴더 밖(`~/.dure/settings/`)에 둔다.** 폴더 안에 두면 조율자가
/// 자기 권한 파일을 고쳐 다음 기동에 권한을 넓힐 수 있다.
enum SessionSettings {

    static let gitReadSubcommands = ["log", "status", "diff", "show"]

    static func dir(root: URL = HookBridge.home) -> URL {
        root.appendingPathComponent("settings", isDirectory: true)
    }

    static func repoPaneURL(root: URL = HookBridge.home) -> URL {
        dir(root: root).appendingPathComponent("repo-pane.json")
    }

    static func orchestratorURL(_ workspaceID: String, root: URL = HookBridge.home) -> URL {
        dir(root: root).appendingPathComponent("orchestrator-\(workspaceID).json")
    }

    static func repoPaneJSON() throws -> Data {
        try encode([
            "hooks": HookBridge.hooksObject(),
            "permissions": ["deny": ["SendMessage", "ListAgents"]],
        ])
    }

    static func orchestratorJSON(repoPaths: [String]) throws -> Data {
        try encode([
            "hooks": HookBridge.hooksObject(),
            "permissions": [
                "allow": repoPaths.flatMap { gitReadRules(repoPath: $0) },
                "deny": repoPaths.flatMap { gitWriteDenyRules(repoPath: $0) },
            ],
        ])
    }

    /// 경로를 셸이 실행할 때의 모양으로. Claude Code 는 실행될 명령 문자열과 규칙을 비교하므로
    /// 조율자가 `git -C '<공백 경로>' log` 로 치면 규칙도 같은 인용이어야 맞는다.
    /// 안전한 글자만 있으면 맨 경로, 아니면 `Spawn.quoted` 와 같은 작은따옴표 인용.
    static func gitPathToken(_ path: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return Spawn.quoted(path)
    }

    static func gitReadRules(repoPath: String) -> [String] {
        let token = gitPathToken(repoPath)
        return gitReadSubcommands.map { "Bash(git -C \(token) \($0) *)" }
    }

    /// 허용한 읽기 명령에도 `--output=<파일>` 이 붙으면 git 이 파일을 쓴다(실측: allow 만 있으면
    /// `git -C <레포> diff --output=x` 가 파일을 만들었다). git 쓰기 금지(ADR-4)를 지키려고
    /// deny 로 막는다. deny 가 allow 보다 우선이라 `diff --stat` 같은 일반 읽기는 그대로 돈다.
    static func gitWriteDenyRules(repoPath: String) -> [String] {
        ["Bash(git -C \(gitPathToken(repoPath)) *--output*)"]
    }

    static func writeRepoPane(root: URL = HookBridge.home) throws {
        try write(try repoPaneJSON(), to: repoPaneURL(root: root))
    }

    @discardableResult
    static func writeOrchestrator(_ workspaceID: String, repoPaths: [String],
                                  root: URL = HookBridge.home) throws -> URL {
        let url = orchestratorURL(workspaceID, root: root)
        try write(try orchestratorJSON(repoPaths: repoPaths), to: url)
        return url
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// 권한이 담긴 파일이라 소유자만 읽고 쓰게 한다. 원자적으로 써서 반쯤 쓰인 설정으로 뜨는 일을 막는다.
    private static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
