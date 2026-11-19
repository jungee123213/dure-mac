import Foundation

/// 이슈 #16 · D-31 — 페인 종류별 `claude --settings` 파일.
///
/// `--settings` 는 파일 하나만 받는다. 그래서 훅(F3)과 권한을 한 파일에 합친다.
/// - 레포 페인: 훅 + 두레 MCP 허용 + `SendMessage`·`ListAgents` 거부. D-29 처럼 레포 에이전트가 맥 전체 세션에
///   메시지를 뿌리는 것을 막는다.
/// - 조율자: 훅 + 레포 절대경로별 git **읽기** 허용 + 두레 MCP 허용 + 메시지 차단(D-32). 조율자 cwd 는 워크스페이스 폴더라 레포 git 은
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

    /// 단계 4 — 두레 MCP 툴. 없으면 `dispatch` 마다 승인이 뜬다(실측).
    static let mcpAllowRule = "mcp__\(DureTools.serverName)__*"

    /// #40 · 스펙 5-4b — 배분받은 레포 페인이 이슈 등록 · 브랜치 · 커밋 · push · PR 을 승인 창 없이 한다.
    /// 승인 창이 뜨면 페인이 멈춰 "진행 한 번" 이 깨진다. 모든 레포 페인이 같이 쓰는 파일이라 사람이 직접 친 작업에도 적용된다.
    ///
    /// push 는 꼬리말의 유일한 모양 `git push -u origin <브랜치>` 만 연다. 규칙은 지금 브랜치를 못 보므로 `git push *` 를 열면
    /// `git push origin` · `--no-verify` · `origin @` 처럼 브랜치를 안 적은 push 가 push.default=simple 로 지금 브랜치(develop 등)를
    /// 승인 없이 밀었다(재리뷰). 막는 목록으로는 다 닫을 수 없어 허용을 좁혔다. 다른 push 모양은 #40 전처럼 묻는다.
    ///
    /// #42 — `pr-draft` 스킬이 기준 브랜치 감지 · 열린 PR 확인에 쓰는 읽기 전용 `gh pr list` · `gh pr view` 도 연다(실측: 없으면 창이 떴다).
    /// `git ls-remote` 는 열지 않는다 — `--upload-pack=<명령>` 으로 임의 프로그램을 돌린다. 스킬은 `git fetch --prune` 뒤 `git branch -r` 로 본다.
    static let repoGitAllow = [
        "Bash(gh issue create *)", "Bash(gh pr create *)", "Bash(gh pr list *)", "Bash(gh pr view *)",
        "Bash(git fetch)", "Bash(git fetch *)", "Bash(git switch *)", "Bash(git checkout -b *)",
        "Bash(git add *)", "Bash(git commit *)", "Bash(git push -u origin *)",
    ]

    /// 되돌리기 어려운 것은 매번 묻는다. Claude Code 는 deny → ask → allow 순으로 보므로 위 allow 보다 이긴다.
    /// 기본 브랜치는 레포마다 이름이 달라(공용 파일) `main` · `develop` · `master` 를 다 둔다.
    ///
    /// 실측(D-43, `claude -p` 2.1.327)으로 더한 것 — 시작값만 두면 아래가 **승인 없이 나갔다**:
    /// - `git push origin HEAD:main` — `* main` 은 앞에 공백이 있어야 맞는다. 그래서 `*:main` 을 따로 둔다.
    ///   뒤에 인자가 붙은 `origin main --tags`, 전체 이름 `HEAD:refs/heads/main` 도 따로 둔다
    /// - 첫 인자가 force 인 `--force-with-lease=<ref> …` · 묶은 `-fu` — `--force *` 는 공백이, `* --force*` 는 앞 인자가 있어야 맞는다.
    ///   그래서 공백 없는 `--force*` · `-f*` 를 둔다(`-u origin x` 는 안 걸린다, 실측)
    /// - `git push origin +x`(refspec `+` 는 force) · `git push -d` · `git push origin :x`(삭제) · `--mirror` · `--prune`
    /// - `git switch -f` · `--discard-changes` · `-C` — 커밋 안 한 작업을 버리거나 브랜치를 덮는다(`git switch *` allow 에 걸린다)
    ///
    /// - (최종 리뷰 I-1 · 재리뷰) 승인 없이 도는 push 는 `git push -u origin <브랜치>` 하나뿐이다(allow 를 그 모양으로 좁혔다).
    ///   그 밖의 push 모양은 allow 에 없어 #40 전처럼 묻는다. 아래는 allow 모양 안에서도 **늘 묻는** 것 — 기본 브랜치 · force · 삭제 —
    ///   과, allow 가 다시 넓어져도 막히게 남겨 둔 브랜치 없는 push 다: 맨 `git push` · `git push -u origin`(끝 ` *` 는 인자 없는 꼴에도
    ///   맞는다, 실측) · `* HEAD` · `*--all*` · `*--tags*`(`--follow-tags` 는 `--tags` 를 품지 않는다),
    ///   콜론 refspec · 전체 이름에 뒤 인자가 붙은 `HEAD:main --tags` · `HEAD:refs/heads/main --tags`
    ///
    /// ⚠️ 규칙 끝이 `:*` 면 Claude Code 가 옛 접두 문법으로 읽어 glob 이 아니게 된다(실측: `* :*` 는 `:x` 삭제를 못 잡았다).
    /// 그래서 `* :**` 로 쓴다. 맨 `git push -f` 같은 인자 없는 모양은 `-f *` 가 잡는다(실측). 대소문자는 가린다(`-c` 는 `-C *` 에 안 걸린다).
    static let repoGitAsk = [
        "Bash(git push --force *)", "Bash(git push -f *)", "Bash(git push --force-with-lease *)",
        "Bash(git push * --force*)", "Bash(git push * -f)", "Bash(git push * -f *)",
        "Bash(git push --force*)", "Bash(git push -f*)",
        "Bash(git push * main)", "Bash(git push * develop)", "Bash(git push * master)",
        "Bash(git push *:main)", "Bash(git push *:develop)", "Bash(git push *:master)",
        "Bash(git push * main *)", "Bash(git push * develop *)", "Bash(git push * master *)",
        "Bash(git push *refs/heads/main)", "Bash(git push *refs/heads/develop)",
        "Bash(git push *refs/heads/master)",
        "Bash(git push)", "Bash(git push -u origin)", "Bash(git push * HEAD)", "Bash(git push *--all*)", "Bash(git push *--tags*)",
        "Bash(git push *:main *)", "Bash(git push *:develop *)", "Bash(git push *:master *)",
        "Bash(git push *refs/heads/main *)", "Bash(git push *refs/heads/develop *)",
        "Bash(git push *refs/heads/master *)",
        "Bash(git push * +*)",
        "Bash(git push --delete *)", "Bash(git push * --delete *)",
        "Bash(git push -d *)", "Bash(git push * -d *)", "Bash(git push * :**)",
        "Bash(git push *--mirror*)", "Bash(git push *--prune*)",
        "Bash(gh pr merge *)", "Bash(git merge *)", "Bash(git rebase *)",
        "Bash(git reset --hard)", "Bash(git reset --hard *)",
        "Bash(git branch -d *)", "Bash(git branch -D *)",
        "Bash(git switch -f*)", "Bash(git switch *--force*)", "Bash(git switch *--discard-changes*)",
        "Bash(git switch -C *)",
        "Bash(git commit --amend*)", "Bash(git commit * --amend*)",
    ]

    static func repoPaneJSON() throws -> Data {
        try encode([
            "hooks": HookBridge.hooksObject(),
            "permissions": ["allow": [mcpAllowRule] + repoGitAllow,
                            "ask": repoGitAsk,
                            "deny": ["SendMessage", "ListAgents"]],
        ])
    }

    /// D-32 — 조율자도 `SendMessage` · `ListAgents` 를 막는다. 배분은 두레 툴로만 간다(범위가 소켓으로 강제된다).
    static func orchestratorJSON(repoPaths: [String]) throws -> Data {
        try encode([
            "hooks": HookBridge.hooksObject(),
            "permissions": [
                "allow": repoPaths.flatMap { gitReadRules(repoPath: $0) } + [mcpAllowRule],
                "deny": repoPaths.flatMap { gitWriteDenyRules(repoPath: $0) } + ["SendMessage", "ListAgents"],
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

    // MARK: - 감시자 (#23)

    static func observerURL(root: URL = HookBridge.home) -> URL {
        dir(root: root).appendingPathComponent("observer.json")
    }

    /// 묻기 페인(`Spawn` 이 `--settings` 를 요구한다). **훅을 넣지 않는다** — 감시자 세션이 두레 이벤트를 만들면 안 된다.
    /// 툴 · MCP 격리는 `EvalSpec.isolationArgs` 의 플래그가 맡는다. 여기는 메시지만 한 번 더 막는다.
    static func observerJSON() throws -> Data {
        try encode(["permissions": ["deny": ["SendMessage", "ListAgents"]]])
    }

    static func writeObserver(root: URL = HookBridge.home) throws {
        try write(try observerJSON(), to: observerURL(root: root))
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
