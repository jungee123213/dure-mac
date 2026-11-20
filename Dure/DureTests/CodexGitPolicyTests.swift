import Foundation
import Testing
@testable import Dure

struct CodexGitPolicyTests {

    private func argvs(_ c: String) throws -> [[String]] { try CodexGitPolicy.segments(c) }

    private func isDangerous(_ r: CodexGitPolicy.Risk) -> Bool {
        if case .dangerous = r { return true }
        return false
    }

    private func isDeny(_ d: CodexGitPolicy.GateDecision) -> Bool {
        if case .deny = d { return true }
        return false
    }

    // MARK: - Review Focus 1 — 2단계 Codex 배분 글이 시키는 명령 모양

    @Test(arguments: ["git fetch origin", "git switch -c feat/x origin/main", "git add a.swift b.swift", "git commit -m 'feat: x\n\n본문'",
                      "git push -u origin feat/x", "git push --set-upstream origin feat/x", "git status --porcelain",
                      "gh issue create --title 'a' --body 'b'", "gh pr create --base main --head feat/x --title 'a' --body 'b'"])
    func 안전한_흐름은_통과한다(_ c: String) throws {
        let segs = try argvs(c)
        #expect(segs.count == 1)
        #expect(CodexGitPolicy.risk(segs[0]) == .safe)
        #expect(CodexGitPolicy.allowRuleMatches(segs[0]))
        #expect(!CodexGitPolicy.promptRuleMatches(segs[0]))
        #expect(CodexGitPolicy.gateDecision(c) == .pass)
    }

    /// 배분 글의 본문 · 커밋 메시지에는 백틱 · `$(` · push · merge 같은 낱말이 흔하다 — 작은따옴표 안이면 안쪽을 볼 수 없는 꼴이 아니다.
    @Test(arguments: ["gh pr create --base main --title 'fix: x' --body '## 변경\n- `push` 전에 `git merge` 를 막는다\n- $(echo) 는 그대로'",
                      "git commit -m 'feat: `reset --hard` 를 묻게 합니다\n\nbranch -D 도'",
                      "gh issue create --title 'a' --body 'it'\\''s `x` --force'"])
    func 작은따옴표_안의_특수_글자는_안전한_흐름을_막지_않는다(_ c: String) throws {
        #expect(!CodexGitPolicy.hasOpaqueShell(c))
        let segs = try argvs(c)
        #expect(segs.count == 1)
        #expect(CodexGitPolicy.risk(segs[0]) == .safe)
        #expect(CodexGitPolicy.gateDecision(c) == .pass)
    }

    // MARK: - Review Focus 3 — 정형 위험 모양: 게이트는 통과, 규칙이 묻는다

    @Test(arguments: ["git push --force origin feat/x", "git push -f origin feat/x", "git push origin main", "git push -u origin main",
                      "git push origin --delete feat/x", "git reset --hard", "git reset --hard 'HEAD~1'", "git status && git push origin main",
                      "git merge main", "git rebase main", "git branch -D x", "git commit --amend", "gh pr merge 3", "git switch -C x"])
    func 정형_위험_모양은_게이트를_지나_규칙이_묻는다(_ c: String) throws {
        #expect(CodexGitPolicy.gateDecision(c) == .pass)
        let segs = try argvs(c)
        let dangerous = segs.filter { isDangerous(CodexGitPolicy.risk($0)) }
        #expect(!dangerous.isEmpty)
        for argv in dangerous {
            #expect(CodexGitPolicy.promptRuleMatches(argv))
        }
    }

    // MARK: - Review Focus 2 — 규칙을 빠져나가는 모양

    @Test(arguments: ["git push -u origin feat/x --force", "git push -u origin feat/x:main", "git push -u origin +feat/x",
                      "git commit -m x --amend", "git -C . push --force origin b", "git -c a=b push origin main",
                      "bash -c \"git push -f origin b\"", "echo $(git push -f origin b)", "git reset --hard HEAD~1",
                      "git push -u origin feat/x --delete", "git push -u origin :feat/x", "git push -u origin HEAD"])
    func 빠져나가는_모양은_게이트가_막는다(_ c: String) {
        #expect(isDeny(CodexGitPolicy.gateDecision(c)))
    }

    /// 같은 뜻의 다른 모양 — 인자 자체를 본다.
    @Test(arguments: ["git push -u origin feat/x --force-with-lease=feat/x", "git push -u origin feat/x -fq", "git push -fu origin feat/x",
                      "git push -u origin HEAD:refs/heads/main", "git push -u origin feat/x:refs/heads/develop", "git push -u origin feat/x master",
                      "git push -u origin feat/x --mirror", "git push -u origin feat/x --prune", "git push -u origin feat/x --all",
                      "git push -u origin feat/x --tags", "git push -u origin", "git push", "git push origin",
                      "git push -u origin feat/x --forc", "git push -u origin @", "git push -u origin 'refs/heads/*'",
                      "git --git-dir=.git push --force origin b", "git --no-pager push origin main", "/usr/bin/git push --force origin b",
                      "env GIT_TRACE=1 git push -f origin b", "command git push origin main", "git switch -c x --force",
                      "git switch -c x --discard-changes", "git switch --force-create x", "git reset HEAD --hard",
                      "git branch --delete x", "git branch -rd origin/x", "git commit -a --amend -m x", "git commit --amen -m x",
                      "gh pr -R o/r merge 3", "git status; git push -u origin feat/x -f", "git status\ngit push -u origin feat/x:main",
                      "git push -u origin feat/x | cat && git push -u origin x --force", "git -c alias.p=push p -f origin b",
                      "git push -u origin ma\\in"])
    func 같은_뜻의_다른_모양도_막는다(_ c: String) {
        #expect(isDeny(CodexGitPolicy.gateDecision(c)))
    }

    /// HEAD 는 prompt 표에 있지만 승인 창에 대상 브랜치가 안 보인다 — 게이트가 브랜치 이름으로 다시 내게 한다.
    @Test(arguments: ["git push -u origin HEAD", "git push --set-upstream origin HEAD", "git push origin HEAD", "git push origin @"])
    func HEAD_push_는_prompt_가_맞아도_막는다(_ c: String) throws {
        guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
            Issue.record("pass: \(c)"); return
        }
        #expect(why.contains("브랜치 이름"))
        #expect(!why.hasSuffix("."))
    }

    /// allow 는 Claude `Bash(git switch *)` 와 같은 폭 — 이어 하기 배분의 `git switch <브랜치>` 가 창 없이 간다. 위험 꼴은 prompt 가 이긴다.
    @Test func git_switch_는_allow_이고_강제_꼴은_prompt_다() throws {
        let plain = try argvs("git switch feat/x")[0]
        #expect(CodexGitPolicy.risk(plain) == .safe)
        #expect(CodexGitPolicy.allowRuleMatches(plain))
        #expect(!CodexGitPolicy.promptRuleMatches(plain))
        #expect(CodexGitPolicy.gateDecision("git switch feat/x") == .pass)

        let forced = try argvs("git switch -f feat/x")[0]
        #expect(isDangerous(CodexGitPolicy.risk(forced)))
        #expect(CodexGitPolicy.allowRuleMatches(forced))
        #expect(CodexGitPolicy.promptRuleMatches(forced))
        #expect(CodexGitPolicy.gateDecision("git switch -f feat/x") == .pass)
    }

    /// 늘 막히는 꼴은 같은 일을 하는 정형 모양을 알려 준다.
    @Test func 늘_막히는_꼴은_정형_대안을_알려_준다() {
        let cases = [
            ("git push --force-with-lease=feat/x origin feat/x", "git push --force-with-lease origin"),
            ("git push -u origin feat/x --force", "git push --force origin"),
            ("git push origin HEAD:main", "git switch main 로 옮긴 뒤 git push origin main"),
            ("git push origin refs/heads/develop", "git push origin develop"),
            ("git commit -a --amend", "git commit --amend"),
            ("git switch --force-create x", "git switch -C"),
            ("git switch main --force", "git switch --force"),
            ("git reset HEAD --hard", "git reset --hard"),
            ("gh pr -R o/r merge 3", "gh pr merge"),
        ]
        for (c, hint) in cases {
            guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
                Issue.record("pass: \(c)"); continue
            }
            #expect(why.contains(hint), "\(c) → \(why)")
            #expect(!why.hasSuffix("."))
        }
    }

    // MARK: - 보안 리뷰 1차 (C-1 · C-2 · I-1 · I-2)

    /// C-1 — allow 모양 push 에 모르는 옵션(줄임 포함)이 끼면 값이 브랜치 자리를 먹어 현재 브랜치(main 일 수 있다)가 나간다.
    @Test(arguments: ["git push -u origin --recurse-submodules no", "git push -u origin --rep x", "git push -u origin --exe x",
                      "git push -u origin --receive x", "git push -u origin feat/x --receive-pack=x", "git push -u origin feat/x -4",
                      "git push --force origin feat/x --exe x", "git push origin main --repo x"])
    func push_의_모르는_옵션은_막는다(_ c: String) {
        guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
            Issue.record("pass: \(c)"); return
        }
        #expect(why.contains("정형 모양"))
        #expect(!why.hasSuffix("."))
    }

    @Test(arguments: ["git push -u origin feat/x --no-verify", "git push -u origin feat/x -q", "git push -u origin feat/x -qv",
                      "git push -u origin feat/x --follow-tags", "git push -u origin feat/x -o ci.skip",
                      "git push -u origin feat/x --push-option=ci.skip", "git push -u origin feat/x --atomic --porcelain --progress",
                      "git push -u origin feat/x -n", "git push -u origin feat/x --dry-run -v"])
    func push_의_아는_옵션은_안전하다(_ c: String) throws {
        let segs = try argvs(c)
        #expect(CodexGitPolicy.risk(segs[0]) == .safe)
        #expect(CodexGitPolicy.gateDecision(c) == .pass)
    }

    /// C-2 — `--upload-pack`(줄임 · `=` · 따로 준 값) 과 위험한 git 설정은 샌드박스 밖에서 임의 명령을 돌린다.
    @Test(arguments: ["git fetch --upload-pack='git push origin main; git-upload-pack' .", "git fetch --upload-pack \"x\" ../r.git",
                      "git fetch --upl=x .", "git fetch origin --up x", "git -c core.sshCommand=x fetch origin",
                      "git -c remote.origin.uploadpack=x fetch origin", "git -c remote.origin.receivepack=x push -u origin feat/x",
                      "git --config-env=core.sshCommand=X fetch origin", "git -c core.hooksPath=/tmp/h commit -m x"])
    func fetch_의_upload_pack_과_위험한_설정은_막는다(_ c: String) {
        #expect(isDeny(CodexGitPolicy.gateDecision(c)))
    }

    /// I-1 — Codex 는 `zsh -lc` 로 돌린다. 따옴표 밖 `? [ ] *` 는 맞는 파일이 있으면 `main` 으로 펼쳐진다.
    @Test(arguments: ["git push -u origin ma?n", "git push -u origin ma[i]n", "git push -u origin feat/x ma?n", "git fetch origin ma?n:x"])
    func push_fetch_의_글롭_글자는_작은따옴표를_안내한다(_ c: String) {
        guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
            Issue.record("pass: \(c)"); return
        }
        #expect(why.contains("작은따옴표"))
    }

    @Test func 글롭은_push_fetch_가_아니면_샌드박스_몫이다() {
        #expect(CodexGitPolicy.gateDecision("git add *.swift") == .pass)
        #expect(CodexGitPolicy.gateDecision("ls Dure/*.swift") == .pass)
        #expect(CodexGitPolicy.gateDecision("git push -u origin 'ma?n'") == .pass)
    }

    /// I-2 — git · gh 앞의 환경 변수는 설정을 바꿀 수 있다(GIT_CONFIG_* · GIT_DIR · HOME …).
    @Test(arguments: ["GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=refs/heads/feat/x:refs/heads/main git push -u origin feat/x",
                      "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=refs/heads/feat/x:refs/heads/main git push -u origin feat/x",
                      "GIT_DIR=../other/.git git commit -m x", "GH_REPO=o/r gh pr create --title a --body b",
                      "HOME=/tmp/x git push -u origin feat/x", "env -i GIT_SSH_COMMAND=x git fetch origin"])
    func git_gh_앞의_환경_변수는_막는다(_ c: String) {
        guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
            Issue.record("pass: \(c)"); return
        }
        #expect(why.contains("환경 변수"))
    }

    @Test func 따옴표_밖_특수_글자가_든_위험_조각은_작은따옴표를_안내한다() {
        for c in ["git reset --hard HEAD~1", "git reset --hard HEAD^", "git push --force origin b~0:b", "git push --force origin {a,b}"] {
            guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
                Issue.record("pass: \(c)"); continue
            }
            #expect(why.contains("작은따옴표"))
        }
        #expect(CodexGitPolicy.gateDecision("git reset --hard 'HEAD^'") == .pass)
        // 위험하지 않은 조각의 특수 글자는 샌드박스 몫
        #expect(CodexGitPolicy.gateDecision("git log HEAD~1") == .pass)
    }

    @Test func 막는_안내는_정형_모양을_알려_주고_마침표로_끝나지_않는다() {
        for c in ["git push -u origin feat/x --force", "git commit -m x --amend", "git -C . push --force origin b",
                  "git reset --hard HEAD~1", "bash -c \"git push -f origin b\"", "git commit -m 'a", "git push"] {
            guard case .deny(let why) = CodexGitPolicy.gateDecision(c) else {
                Issue.record("pass: \(c)"); continue
            }
            #expect(!why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!why.hasSuffix("."))
        }
        if case .deny(let why) = CodexGitPolicy.gateDecision("git push -u origin feat/x --force") {
            #expect(why.contains("정형 모양"))
            #expect(why.contains("git push --force"))
        }
    }

    // MARK: - 셸 단어 · 조각

    @Test func 셸_단어를_POSIX_처럼_나눈다() throws {
        #expect(try argvs("git commit -m 'a b' \"c \\\"d\\\" \\\\\" e\\ f") == [["git", "commit", "-m", "a b", "c \"d\" \\", "e f"]])
        #expect(try argvs("a && b || c; d | e & f\ng") == [["a"], ["b"], ["c"], ["d"], ["e"], ["f"], ["g"]])
        #expect(try argvs("echo 'a && b' \"c; d\" e\\;f") == [["echo", "a && b", "c; d", "e;f"]])
        #expect(try argvs("git push -u origin feat/x # --force") == [["git", "push", "-u", "origin", "feat/x"]])
        #expect(try argvs("a'b'\"c\"d") == [["abcd"]])
        #expect(try argvs("echo ''") == [["echo", ""]])
        #expect(try argvs("") == [])
    }

    @Test func 조각은_따옴표_밖_특수_글자를_함께_돌려준다() throws {
        let segs = try CodexGitPolicy.parse("git reset --hard HEAD~1 'HEAD^' a{b")
        #expect(segs.count == 1)
        #expect(segs[0].words.map(\.text) == ["git", "reset", "--hard", "HEAD~1", "HEAD^", "a{b"])
        #expect(segs[0].words.map(\.unquotedSpecial) == [false, false, false, true, false, true])
    }

    @Test(arguments: ["git commit -m 'a", "git commit -m \"a", "echo \\", "gh pr create --body 'x\"y"])
    func 닫히지_않은_따옴표는_막는다(_ c: String) {
        #expect(throws: (any Error).self) { try CodexGitPolicy.segments(c) }
        #expect(isDeny(CodexGitPolicy.gateDecision(c)))
    }

    @Test(arguments: ["ls -la", "rg foo", "swift test", "cat a | grep b", "git log --oneline -5", "git diff --stat",
                      "git rev-parse --abbrev-ref origin/HEAD", "git branch -r", "git push origin feat/x",
                      "echo $(date)", "ls `pwd`", "cat a | xargs grep b"])
    func 위험과_무관한_명령은_통과한다(_ c: String) {
        #expect(CodexGitPolicy.gateDecision(c) == .pass)
    }

    @Test func 안쪽을_볼_수_없는_꼴() {
        for c in ["echo $(x)", "echo `x`", "diff <(a) b", "bash -c 'x'", "sh -c x", "zsh -lc x", "/bin/bash -ec x",
                  "eval x", "a && xargs b", "echo \"$(x)\"", "FOO=1 bash -c x", "(git push -f origin b)"] {
            #expect(CodexGitPolicy.hasOpaqueShell(c), "\(c)")
        }
        for c in ["echo '$(x)'", "echo '`x`'", "bash script.sh", "echo eval", "git status", "echo 'a (b)'", "echo \\$x y"] {
            #expect(!CodexGitPolicy.hasOpaqueShell(c), "\(c)")
        }
    }

    @Test func 안쪽을_볼_수_없는_꼴은_위험_낱말이_있을_때만_막는다() {
        #expect(!CodexGitPolicy.opaqueDangerWords.isEmpty)
        for w in CodexGitPolicy.opaqueDangerWords {
            #expect(isDeny(CodexGitPolicy.gateDecision("bash -c 'x \(w) y'")), "\(w)")
        }
        #expect(isDeny(CodexGitPolicy.gateDecision("git push -u origin $(git branch --show-current)")))
        #expect(isDeny(CodexGitPolicy.gateDecision("(git push -f origin b)")))
        #expect(CodexGitPolicy.gateDecision("echo $(git log -1)") == .pass)
    }

    // MARK: - 판정

    @Test func 위험_이유를_돌려준다() {
        guard case .dangerous(let why) = CodexGitPolicy.risk(["git", "push", "-u", "origin", "feat/x", "--force"]) else {
            Issue.record("not dangerous"); return
        }
        #expect(!why.isEmpty)
        #expect(CodexGitPolicy.risk(["ls"]) == .other)
        #expect(CodexGitPolicy.risk(["git", "log"]) == .other)
        #expect(CodexGitPolicy.risk(["git", "-C", ".", "status"]) == .other)  // 규칙은 접두라 -C 가 끼면 allow 가 아니다
        #expect(CodexGitPolicy.risk(["git", "commit", "-m", "--amend"]) == .safe) // 메시지 값은 옵션이 아니다
        #expect(CodexGitPolicy.risk(["git", "switch", "-c", "feat/fix"]) == .safe)
        #expect(CodexGitPolicy.risk(["git", "push", "-u", "origin", "HEAD:feat/x"]) == .safe)
        #expect(CodexGitPolicy.risk(["gh", "pr", "create", "--title", "merge"]) == .safe)
    }

    @Test func 규칙_일치는_정형_접두만_본다() {
        #expect(CodexGitPolicy.allowRuleMatches(["git", "push", "-u", "origin"]))
        #expect(!CodexGitPolicy.allowRuleMatches(["git", "push", "origin", "feat/x"]))
        #expect(!CodexGitPolicy.allowRuleMatches(["git", "push", "-u"]))
        #expect(CodexGitPolicy.allowRuleMatches(["gh", "pr", "view", "3"]))
        #expect(!CodexGitPolicy.allowRuleMatches(["gh", "pr", "merge", "3"]))
        // allow 와 prompt 가 둘 다 맞는 모양(Codex 는 prompt)
        #expect(CodexGitPolicy.allowRuleMatches(["git", "push", "-u", "origin", "main"]))
        #expect(CodexGitPolicy.promptRuleMatches(["git", "push", "-u", "origin", "main"]))
        #expect(CodexGitPolicy.promptRuleMatches(["git", "push", "--set-upstream", "origin", "HEAD"]))
        #expect(CodexGitPolicy.promptRuleMatches(["git", "push", "origin", "--tags"]))
        #expect(!CodexGitPolicy.promptRuleMatches(["git", "switch", "-c", "x"])) // 대소문자를 가린다
        #expect(!CodexGitPolicy.promptRuleMatches(["git", "reset", "HEAD", "--hard"]))
        #expect(!CodexGitPolicy.promptRuleMatches([]))
    }

    @Test func 규칙_파일은_allow_와_prompt_를_모두_담는다() {
        let f = CodexGitPolicy.rulesFile()
        #expect(f.contains(#"decision="allow""#))
        #expect(f.contains(#"decision="prompt""#))
        #expect(!f.contains(#"decision="forbidden""#))
        #expect(f.contains(#"prefix_rule(pattern=["git", "fetch"], decision="allow""#))
        #expect(f.contains(#"prefix_rule(pattern=["git", "switch"], decision="allow""#))
        #expect(f.contains(#"["git", "push", ["-u", "--set-upstream"], "origin"], decision="allow""#))
        #expect(f.contains(#"["gh", "pr", ["create", "list", "view"]], decision="allow""#))
        #expect(f.contains(#"["git", "push", ["--force", "--force-with-lease", "-f"]], decision="prompt""#))
        #expect(f.contains(#"["git", "reset", "--hard"], decision="prompt""#))
        #expect(f.contains(#"["gh", "pr", "merge"], decision="prompt""#))
        #expect(f.contains(#"justification="두레"#))
        let rules = f.components(separatedBy: "\n").filter { $0.hasPrefix("prefix_rule(") }
        #expect(rules.count == CodexGitPolicy.allowRules.count + CodexGitPolicy.promptRules.count)
        #expect(rules.allSatisfy { $0.contains("justification=\"두레 ") })
    }

    // MARK: - Claude 와 같은 뜻

    /// `SessionSettings.repoGitAsk` 의 규칙마다 그 규칙에 맞는 대표 명령. 규칙이 늘면 여기도 는다(아래 완전성 검사).
    static let claudeAskSamples: [(rule: String, command: String)] = [
        ("Bash(git push --force *)", "git push --force origin feat/x"),
        ("Bash(git push -f *)", "git push -f origin feat/x"),
        ("Bash(git push --force-with-lease *)", "git push --force-with-lease origin feat/x"),
        ("Bash(git push * --force*)", "git push -u origin feat/x --force-with-lease=feat/x"),
        ("Bash(git push * -f)", "git push -u origin feat/x -f"),
        ("Bash(git push * -f *)", "git push origin -f feat/x"),
        ("Bash(git push --force*)", "git push --force-with-lease=feat/x origin feat/x"),
        ("Bash(git push -f*)", "git push -fu origin feat/x"),
        ("Bash(git push * main)", "git push origin main"),
        ("Bash(git push * develop)", "git push -u origin develop"),
        ("Bash(git push * master)", "git push --set-upstream origin master"),
        ("Bash(git push *:main)", "git push origin HEAD:main"),
        ("Bash(git push *:develop)", "git push -u origin feat/x:develop"),
        ("Bash(git push *:master)", "git push origin feat/x:master"),
        ("Bash(git push * main *)", "git push origin main --no-verify"),
        ("Bash(git push * develop *)", "git push origin develop -u"),
        ("Bash(git push * master *)", "git push origin master --quiet"),
        ("Bash(git push *refs/heads/main)", "git push -u origin feat/x:refs/heads/main"),
        ("Bash(git push *refs/heads/develop)", "git push origin refs/heads/develop"),
        ("Bash(git push *refs/heads/master)", "git push origin HEAD:refs/heads/master"),
        ("Bash(git push)", "git push"),
        ("Bash(git push -u origin)", "git push -u origin"),
        ("Bash(git push * HEAD)", "git push origin HEAD"),
        ("Bash(git push *--all*)", "git push --all origin"),
        ("Bash(git push *--tags*)", "git push -u origin feat/x --tags"),
        ("Bash(git push *:main *)", "git push origin HEAD:main --verbose"),
        ("Bash(git push *:develop *)", "git push -u origin x:develop -q"),
        ("Bash(git push *:master *)", "git push origin x:master -v"),
        ("Bash(git push *refs/heads/main *)", "git push origin HEAD:refs/heads/main --verbose"),
        ("Bash(git push *refs/heads/develop *)", "git push -u origin x:refs/heads/develop -q"),
        ("Bash(git push *refs/heads/master *)", "git push origin refs/heads/master --no-verify"),
        ("Bash(git push * +*)", "git push -u origin +feat/x"),
        ("Bash(git push --delete *)", "git push --delete origin feat/x"),
        ("Bash(git push * --delete *)", "git push origin --delete feat/x"),
        ("Bash(git push -d *)", "git push -d origin feat/x"),
        ("Bash(git push * -d *)", "git push -u origin -d feat/x"),
        ("Bash(git push * :**)", "git push -u origin :feat/x"),
        ("Bash(git push *--mirror*)", "git push --mirror origin"),
        ("Bash(git push *--prune*)", "git push -u origin feat/x --prune"),
        ("Bash(gh pr merge *)", "gh pr merge 3 --squash"),
        ("Bash(git merge *)", "git merge feat/x"),
        ("Bash(git rebase *)", "git rebase -i main"),
        ("Bash(git reset --hard)", "git reset --hard"),
        ("Bash(git reset --hard *)", "git reset --hard origin/main"),
        ("Bash(git branch -d *)", "git branch -d feat/x"),
        ("Bash(git branch -D *)", "git branch -D feat/x"),
        ("Bash(git switch -f*)", "git switch -f main"),
        ("Bash(git switch *--force*)", "git switch main --force"),
        ("Bash(git switch *--discard-changes*)", "git switch --discard-changes main"),
        ("Bash(git switch -C *)", "git switch -C feat/x origin/main"),
        ("Bash(git commit --amend*)", "git commit --amend --no-edit"),
        ("Bash(git commit * --amend*)", "git commit -a --amend"),
    ]

    /// Claude Code 의 `Bash(…)` 규칙을 glob 으로 — `*` 는 아무 글자(빈 것 포함), 끝 ` *` 는 인자 없는 꼴에도 맞는다(실측, SessionSettings 주석).
    private static func claudeRuleMatches(_ rule: String, _ command: String) -> Bool {
        var body = String(rule.dropFirst("Bash(".count).dropLast())
        var alts = [body]
        if body.hasSuffix(" *") { body.removeLast(2); alts.append(body) }
        return alts.contains { pattern in
            let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
            return command.range(of: regex, options: .regularExpression) != nil
        }
    }

    @Test func Claude_ask_목록의_대표_모양은_모두_위험이다() throws {
        let covered = Set(Self.claudeAskSamples.map(\.rule))
        for rule in SessionSettings.repoGitAsk {
            #expect(covered.contains(rule), "대표 명령 없음: \(rule)")
        }
        for (rule, command) in Self.claudeAskSamples {
            #expect(SessionSettings.repoGitAsk.contains(rule), "목록에 없는 규칙: \(rule)")
            #expect(Self.claudeRuleMatches(rule, command), "\(command) 가 \(rule) 에 안 맞는다")
            let segs = try argvs(command)
            #expect(segs.count == 1)
            #expect(isDangerous(CodexGitPolicy.risk(segs[0])), "\(command)")
        }
    }

    /// 반대쪽 — Claude allow 가 묻지 않고 내보내는 대표 모양은 위험이 아니다.
    @Test(arguments: ["git fetch", "git fetch origin", "git switch feat/x", "git switch -c feat/x origin/main", "git add a.swift",
                      "git commit -m x", "git push -u origin feat/x", "gh issue create --title a --body b", "gh pr create --title a --body b",
                      "gh pr list", "gh pr view 3", "git checkout -b feat/x"])
    func Claude_allow_의_대표_모양은_위험이_아니다(_ c: String) throws {
        let segs = try argvs(c)
        #expect(!isDangerous(CodexGitPolicy.risk(segs[0])))
    }
}
