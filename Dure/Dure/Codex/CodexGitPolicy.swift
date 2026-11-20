import Foundation

/// Codex 레포 페인의 git · gh 판정 원본 — 규칙 파일(`rules/dure.rules`)과 PreToolUse 게이트가 같은 표를 본다.
/// 앱 밖(게이트 실행)에서도 돌아 `nonisolated`. 파일 · 프로세스를 건드리지 않는 순수 코드.
///
/// 실측(docs/spikes/2026-11-19-codex/i-stage3.md):
/// - Codex 규칙은 토큰 **접두** 일치, allow 와 prompt 가 둘 다 맞으면 prompt 가 이긴다.
/// - 실제 턴은 `&&` · `;` · `|` 조각을 따로 검사한다.
/// - 따옴표 밖 `~` · `^` · `{` · `}` 가 든 인자가 있으면 Codex 는 규칙을 건너뛰고 샌드박스로 보낸다.
/// - 명령 치환 · `bash -c` · 서브셸은 규칙을 건너뛴다(샌드박스만 막는다).
///
/// 위험 범위는 Claude `SessionSettings.repoGitAsk` 와 같은 뜻이다. 다만 접두가 아니라 **인자 자체**를 본다 —
/// allow 접두 뒤에 `--force` · `b:main` · `+b` 가 붙는 구멍(spike C · E)을 게이트가 막는다.
nonisolated enum CodexGitPolicy {

    // MARK: - 규칙 표

    enum Part: Equatable {
        case one(String)
        case any([String])

        func matches(_ token: String) -> Bool {
            switch self {
            case .one(let s): return s == token
            case .any(let xs): return xs.contains(token)
            }
        }
    }

    struct Rule: Equatable {
        let pattern: [Part]
        let justification: String

        func matches(_ argv: [String]) -> Bool {
            guard !pattern.isEmpty, argv.count >= pattern.count else { return false }
            return zip(pattern, argv).allSatisfy { $0.matches($1) }
        }
    }

    static let defaultBranches = ["main", "develop", "master"]
    private static let upstream = Part.any(["-u", "--set-upstream"])

    /// 샌드박스 밖에서 묻지 않고 도는 정형 모양(2단계 Codex 배분 글이 시키는 명령).
    static let allowRules: [Rule] = [
        Rule(pattern: [.one("git"), .one("fetch")], justification: "두레 안전: git fetch"),
        Rule(pattern: [.one("git"), .one("switch")], justification: "두레 안전: 브랜치 옮기기 · 새 브랜치"),  // Claude `Bash(git switch *)` 와 같은 폭, 위험 꼴은 prompt 가 이긴다
        Rule(pattern: [.one("git"), .one("add")], justification: "두레 안전: git add"),
        Rule(pattern: [.one("git"), .one("commit"), .one("-m")], justification: "두레 안전: 커밋"),
        Rule(pattern: [.one("git"), .one("push"), upstream, .one("origin")], justification: "두레 안전: 작업 브랜치 push"),
        Rule(pattern: [.one("git"), .one("status")], justification: "두레 안전: git status"),
        Rule(pattern: [.one("gh"), .one("issue"), .one("create")], justification: "두레 안전: 이슈 등록"),
        Rule(pattern: [.one("gh"), .one("pr"), .any(["create", "list", "view"])], justification: "두레 안전: PR 등록 · 보기"),
    ]

    /// 사람에게 묻는 정형 위험 모양. allow 와 겹치면 Codex 는 이쪽(prompt)을 고른다.
    static let promptRules: [Rule] = [
        Rule(pattern: [.one("git"), .one("push"), .any(["--force", "--force-with-lease", "-f"])], justification: "두레 위험: force push"),
        Rule(pattern: [.one("git"), .one("push"), upstream, .one("origin"), .any(defaultBranches + ["HEAD"])],
             justification: "두레 위험: 기본 브랜치 · HEAD push"),
        Rule(pattern: [.one("git"), .one("push"), .one("origin"),
                       .any(defaultBranches + ["HEAD", "--delete", "-d", "--mirror", "--prune", "--all", "--tags"])],
             justification: "두레 위험: 기본 브랜치 · 삭제 · 전체 push"),
        Rule(pattern: [.one("git"), .one("push"), .one("--delete")], justification: "두레 위험: 원격 브랜치 삭제"),
        Rule(pattern: [.one("git"), .one("push"), .one("-d")], justification: "두레 위험: 원격 브랜치 삭제"),
        Rule(pattern: [.one("git"), .one("merge")], justification: "두레 위험: merge"),
        Rule(pattern: [.one("git"), .one("rebase")], justification: "두레 위험: rebase"),
        Rule(pattern: [.one("git"), .one("reset"), .one("--hard")], justification: "두레 위험: reset --hard"),
        Rule(pattern: [.one("git"), .one("branch"), .any(["-d", "-D"])], justification: "두레 위험: 브랜치 삭제"),
        Rule(pattern: [.one("git"), .one("switch"), .any(["-f", "--force", "--discard-changes", "-C"])],
             justification: "두레 위험: 작업 버리기 · 브랜치 덮기"),
        Rule(pattern: [.one("git"), .one("commit"), .one("--amend")], justification: "두레 위험: commit --amend"),
        Rule(pattern: [.one("gh"), .one("pr"), .one("merge")], justification: "두레 위험: PR 머지"),
    ]

    /// 각자 맞는지만 본다 — "가장 엄한 것이 이긴다" 는 Codex 몫.
    static func allowRuleMatches(_ argv: [String]) -> Bool { allowRules.contains { $0.matches(argv) } }
    static func promptRuleMatches(_ argv: [String]) -> Bool { promptRules.contains { $0.matches(argv) } }

    /// Codex `rules/dure.rules`(Starlark). `codex execpolicy check -r <파일> -- <토큰…>` 으로 무모델 확인.
    static func rulesFile() -> String {
        var lines = [
            "# 두레가 만든 파일 — 페인을 시작할 때마다 다시 쓴다. 손으로 고치지 않는다.",
            "# 원본: CodexGitPolicy.allowRules · promptRules. 여러 규칙이 맞으면 가장 엄한 것(prompt)이 이긴다.",
        ]
        for (decision, rules) in [("allow", allowRules), ("prompt", promptRules)] {
            for r in rules {
                lines.append("prefix_rule(pattern=\(starlark(r.pattern)), decision=\"\(decision)\", justification=\(starlark(r.justification)))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func starlark(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func starlark(_ pattern: [Part]) -> String {
        "[" + pattern.map { part in
            switch part {
            case .one(let s): return starlark(s)
            case .any(let xs): return "[" + xs.map(starlark).joined(separator: ", ") + "]"
            }
        }.joined(separator: ", ") + "]"
    }

    // MARK: - 셸 단어

    struct ParseError: Error, Equatable {
        let message: String
    }

    struct Word: Equatable {
        let text: String
        /// 따옴표 밖 `~` · `^` · `{` · `}`, 또는 작은따옴표 밖 역슬래시가 있었나.
        /// 이 글자가 있으면 Codex 는 규칙을 건너뛴다(실측). 역슬래시는 Codex 가 셸처럼 풀지 확인하지 못해 같이 본다.
        /// 글롭 `?` · `[` · `]` · `*` 도 든다 — Codex 는 `zsh -lc` 로 돌려 맞는 파일이 있으면 `ma?n` 이 `main` 으로 펼쳐진다(보안 리뷰 I-1).
        let unquotedSpecial: Bool
    }

    struct Segment: Equatable {
        let words: [Word]
        var argv: [String] { words.map(\.text) }
    }

    /// 셸 단어로 나눈 명령 조각들. 연산자 `&&` · `||` · `;` · `|` · `&` · 줄바꿈에서 끊는다(따옴표 안은 글자).
    static func segments(_ command: String) throws -> [[String]] {
        try parse(command).map(\.argv)
    }

    static func parse(_ command: String) throws -> [Segment] {
        try scan(command).segments
    }

    private struct Scan {
        var segments: [Segment] = []
        /// 작은따옴표 밖 `$(` · `${` · `$이름` · 백틱, 따옴표 밖 `$'` · `<(` · `>(` · `(`.
        var opaqueMark = false
    }

    private static let specialScalars: Set<Unicode.Scalar> = ["~", "^", "{", "}", "?", "[", "]", "*"]

    private static func scan(_ command: String) throws -> Scan {
        let s = Array(command.unicodeScalars)
        let n = s.count
        var out = Scan()
        var words: [Word] = []
        var cur = String.UnicodeScalarView()
        var inWord = false
        var special = false
        var quoted = false
        var dropNextWord = false   // 리다이렉션 대상
        var i = 0

        func peek(_ k: Int) -> Unicode.Scalar? { i + k < n ? s[i + k] : nil }

        func endWord() {
            if inWord {
                if dropNextWord {
                    dropNextWord = false
                } else {
                    words.append(Word(text: String(cur), unquotedSpecial: special))
                }
            }
            cur = String.UnicodeScalarView()
            inWord = false
            special = false
            quoted = false
        }

        func endSegment() {
            endWord()
            dropNextWord = false
            if !words.isEmpty { out.segments.append(Segment(words: words)) }
            words = []
        }

        /// `$` 뒤가 매개변수 확장 · 명령 치환이면 안쪽을 볼 수 없다.
        func markDollar() {
            guard let next = peek(1) else { return }
            if next == "(" || next == "{" || next == "_" || "@*#?$!-".unicodeScalars.contains(next)
                || CharacterSet.alphanumerics.contains(next) {
                out.opaqueMark = true
            }
        }

        while i < n {
            let c = s[i]
            switch c {
            case " ", "\t":
                endWord(); i += 1
            case "\n", "\r", ";":
                endSegment(); i += 1
            case "|":
                endSegment()
                i += (peek(1) == "|" || peek(1) == "&") ? 2 : 1
            case "&":
                if peek(1) == "&" {
                    endSegment(); i += 2
                } else if peek(1) == ">" {
                    // `&>` · `&>>` — 리다이렉션
                    endWord(); i += 1
                    while i < n, s[i] == ">" { i += 1 }
                    dropNextWord = true
                } else {
                    endSegment(); i += 1
                }
            case "<", ">":
                if peek(1) == "(" {
                    out.opaqueMark = true
                    cur.append(c); inWord = true; i += 1
                    continue
                }
                // 숫자만인 앞 단어는 파일 번호(`2>`)
                if inWord, !quoted, !cur.isEmpty, cur.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                    cur = String.UnicodeScalarView(); inWord = false; special = false
                }
                endWord()
                while i < n, "<>&|-".unicodeScalars.contains(s[i]) { i += 1 }
                dropNextWord = true
            case "#" where !inWord:
                while i < n, s[i] != "\n" { i += 1 }
            case "(":
                out.opaqueMark = true
                cur.append(c); inWord = true; i += 1
            case "'":
                inWord = true; quoted = true; i += 1
                while i < n, s[i] != "'" { cur.append(s[i]); i += 1 }
                guard i < n else { throw ParseError(message: "닫히지 않은 작은따옴표") }
                i += 1
            case "\"":
                inWord = true; quoted = true; i += 1
                var closed = false
                while i < n {
                    let d = s[i]
                    if d == "\"" { closed = true; i += 1; break }
                    if d == "\\" {
                        guard let next = peek(1) else { break }
                        special = true
                        if next == "\n" { i += 2; continue }
                        if "$`\"\\".unicodeScalars.contains(next) { cur.append(next) } else { cur.append(d); cur.append(next) }
                        i += 2; continue
                    }
                    if d == "$" { markDollar() }
                    if d == "`" { out.opaqueMark = true }
                    cur.append(d); i += 1
                }
                guard closed else { throw ParseError(message: "닫히지 않은 큰따옴표") }
            case "\\":
                guard let next = peek(1) else { throw ParseError(message: "끝에 남은 역슬래시") }
                if next == "\n" { i += 2; continue }
                cur.append(next); inWord = true; special = true; i += 2
            case "`":
                out.opaqueMark = true
                cur.append(c); inWord = true; i += 1
            case "$":
                if peek(1) == "'" { out.opaqueMark = true }
                markDollar()
                cur.append(c); inWord = true; i += 1
            default:
                if specialScalars.contains(c) { special = true }
                cur.append(c); inWord = true; i += 1
            }
        }
        endSegment()
        return out
    }

    // MARK: - 안쪽을 볼 수 없는 꼴

    /// 안쪽을 볼 수 없는 꼴에 이 낱말이 있으면 게이트가 막는다(대소문자 무시, 부분 문자열). 넓게 잡는다 — 틀리면 정형 모양으로 다시 내면 된다.
    static let opaqueDangerWords = ["push", "merge", "rebase", "reset", "branch", "switch", "checkout", "amend", "update-ref"]

    private static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    private static let interpreters: Set<String> = ["python", "python3", "perl", "ruby", "node", "osascript"]

    /// 명령 치환(`$(` · 백틱) · 매개변수 확장 · 프로세스 치환 · 서브셸, `bash|sh|zsh -c` · stdin 셸 · `eval` · `xargs` ·
    /// `find -exec` · 인터프리터 `-c|-e` · `env -S` 처럼 Codex 가 안쪽 명령을 검사하지 않는 꼴. 읽을 수 없는 명령도 여기에 든다.
    static func hasOpaqueShell(_ command: String) -> Bool {
        guard let scanned = try? scan(command) else { return true }
        if scanned.opaqueMark { return true }
        return scanned.segments.contains { isOpaqueSegment($0.argv) }
    }

    private static func isOpaqueSegment(_ argv: [String]) -> Bool {
        let (start, splitString, _) = commandStart(argv)
        if splitString { return true }
        guard let start else { return false }
        let name = basename(argv[start])
        let args = argv[(start + 1)...]
        if name == "eval" || name == "xargs" { return true }
        if shells.contains(name) {
            for a in args {
                if a == "--" { return false }
                if a.hasPrefix("--") { continue }
                if a.hasPrefix("-") || a.hasPrefix("+") {
                    if a.dropFirst().contains("c") || a.dropFirst().contains("s") { return true }
                    continue
                }
                return false   // 스크립트 파일
            }
            return true        // 인자 없음 — stdin 에서 읽는다
        }
        if name == "find" { return args.contains { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) } }
        if interpreters.contains(name) { return args.contains { $0 == "-c" || $0 == "-e" } }
        return false
    }

    private static func dangerWord(in command: String) -> String? {
        let lower = command.lowercased()
        return opaqueDangerWords.first { lower.contains($0) }
    }

    // MARK: - 명령 단어

    private static let reservedWords: Set<String> = ["!", "{", "if", "then", "else", "elif", "do", "while", "until"]

    private static func basename(_ word: String) -> String {
        word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? word
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[..<eq]
        guard let first = name.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// 앞의 `VAR=값` · 감싸는 명령(`env` · `command` · `exec` · `nohup` · `nice` · `time` · `sudo` · `xcrun` · `timeout`) ·
    /// 예약어(`!` · `{` · `if` · `do` …)를 건너 실제 명령 단어의 위치. `splitString` 은 `env -S`(안쪽을 볼 수 없다).
    private static func commandStart(_ argv: [String]) -> (index: Int?, splitString: Bool, assignments: [String]) {
        var i = 0
        let n = argv.count
        var assignments: [String] = []
        func skipOptions(valued: Set<String>) {
            while i < n, argv[i].hasPrefix("-"), argv[i] != "-" {
                if argv[i] == "--" { i += 1; return }
                i += valued.contains(argv[i]) ? 2 : 1
            }
        }
        while i < n {
            let w = argv[i]
            if isAssignment(w) { assignments.append(w); i += 1; continue }
            if reservedWords.contains(w) { i += 1; continue }
            switch basename(w) {
            case "env":
                i += 1
                while i < n {
                    let a = argv[i]
                    if a == "-S" || a.hasPrefix("--split-string") || (a.hasPrefix("-") && !a.hasPrefix("--") && a.contains("S")) {
                        return (nil, true, assignments)
                    }
                    if a == "--" { i += 1; break }
                    if ["-u", "--unset", "-C", "--chdir", "-P"].contains(a) { i += 2; continue }
                    if isAssignment(a) { assignments.append(a); i += 1; continue }
                    if a.hasPrefix("-") { i += 1; continue }
                    break
                }
            case "command", "builtin", "nohup", "time":
                i += 1; skipOptions(valued: [])
            case "exec":
                i += 1; skipOptions(valued: ["-a"])
            case "nice":
                i += 1; skipOptions(valued: ["-n"])
            case "sudo", "doas":
                i += 1; skipOptions(valued: ["-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R", "-T"])
            case "xcrun":
                i += 1; skipOptions(valued: ["--sdk", "-sdk", "--toolchain", "-toolchain"])
            case "timeout", "gtimeout":
                i += 1; skipOptions(valued: ["-s", "--signal", "-k", "--kill-after"])
                i += 1   // 시간
            default:
                return (i, false, assignments)
            }
        }
        return (nil, false, assignments)
    }

    // MARK: - 판정

    enum Risk: Equatable {
        /// allow 규칙 범위
        case safe
        /// 위험 범위(이유)
        case dangerous(String)
        /// 둘 다 아님 — 샌드박스 몫
        case other
    }

    struct Danger: Equatable {
        let reason: String
        /// 같은 일을 하는 정형 모양(prompt 규칙에 맞는 꼴)
        let example: String
        var kind = Kind.promptable

        enum Kind: Equatable {
            /// prompt 규칙에 맞으면 사람이 본다
            case promptable
            /// prompt 규칙에 맞아도 게이트가 막고 정형 모양으로 다시 내게 한다(모르는 옵션 · 설정 · 환경 변수 주입)
            case rewrite
            /// HEAD 는 어느 브랜치로 가는지 승인 창에 안 보인다 — 브랜치 이름으로 다시 내게 한다
            case hidesTarget
        }
    }

    static func risk(_ argv: [String]) -> Risk {
        if let d = danger(argv) { return .dangerous(d.reason) }
        return allowRuleMatches(argv) ? .safe : .other
    }

    static func danger(_ argv: [String]) -> Danger? {
        let found = commandStart(argv)
        guard let start = found.index else { return nil }
        let rest = Array(argv[(start + 1)...])
        let name = basename(argv[start])
        // 보안 리뷰 I-2 — git · gh 앞의 `VAR=값`(바로 앞이든 env 안이든)은 설정을 바꿀 수 있다:
        // GIT_CONFIG_COUNT/KEY/VALUE · GIT_DIR · GIT_SSH_COMMAND · GH_REPO · HOME · XDG_CONFIG_HOME …. 이름을 가리지 않고 막는다.
        if name == "git" || name == "gh", !found.assignments.isEmpty {
            let names = found.assignments.map { String($0.prefix { $0 != "=" }) }.joined(separator: " · ")
            return Danger(reason: "\(name) 앞의 환경 변수(\(names))", example: "환경 변수 없이 \(name) …", kind: .rewrite)
        }
        switch name {
        case "git": return gitDanger(rest)
        case "gh": return ghDanger(rest)
        default: return nil
        }
    }

    /// `--x` 가 이름들 중 하나의 앞부분(git 은 모호하지 않은 긴 옵션 줄임을 받는다). `=값` 은 떼고 본다.
    private static func isLongOption(_ token: String, abbreviating names: [String]) -> Bool {
        guard token.hasPrefix("--"), token != "--" else { return false }
        let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        guard name.count >= 3 else { return false }
        return names.contains { $0.hasPrefix(name) }
    }

    private static func isShortBundle(_ token: String) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token.count >= 2
    }

    private static let gitGlobalValued: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source",
    ]

    /// git 전역 옵션을 건넌 하위 명령의 위치(args 안).
    private static func gitSubcommandIndex(_ args: [String]) -> Int? {
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            i += gitGlobalValued.contains(args[i]) ? 2 : 1
        }
        return i < args.count ? i : nil
    }

    private static func isPushOrFetch(_ argv: [String]) -> Bool {
        guard let start = commandStart(argv).index, basename(argv[start]) == "git" else { return false }
        let rest = Array(argv[(start + 1)...])
        guard let k = gitSubcommandIndex(rest) else { return false }
        return rest[k] == "push" || rest[k] == "fetch"
    }

    private static func gitDanger(_ args: [String]) -> Danger? {
        var i = 0
        let n = args.count
        // 전역 옵션: -C <v> · -c <v> · --git-dir[=v] · --work-tree[=v] · --namespace[=v] · --no-pager · -P · --bare · --exec-path[=v] …
        while i < n, args[i].hasPrefix("-") {
            let t = args[i]
            var value: String?
            if gitGlobalValued.contains(t) {
                value = i + 1 < n ? args[i + 1] : nil
                i += 2
            } else {
                if t.hasPrefix("-c"), t.count > 2, !t.hasPrefix("--") { value = String(t.dropFirst(2)) }
                if t.hasPrefix("--config-env=") { value = String(t.dropFirst("--config-env=".count)) }
                i += 1
            }
            if let value, let key = dangerousConfigKey(value) {
                return Danger(reason: "위험한 git 설정(-c \(key))", example: "-c 없이 git <하위 명령> …", kind: .rewrite)
            }
        }
        guard i < n else { return nil }
        let sub = args[i]
        let rest = Array(args[(i + 1)...])
        switch sub {
        case "push": return pushDanger(rest)
        case "fetch": return fetchDanger(rest)
        case "merge": return Danger(reason: "git merge", example: "git merge <브랜치>")
        case "rebase": return Danger(reason: "git rebase", example: "git rebase <브랜치>")
        case "reset":
            for t in rest {
                if t == "--" { break }
                if isLongOption(t, abbreviating: ["--hard"]) {
                    return Danger(reason: "git reset --hard", example: "git reset --hard '<커밋>'")
                }
            }
            return nil
        case "branch": return branchDanger(rest)
        case "switch": return switchDanger(rest)
        case "commit": return commitDanger(rest)
        default: return nil
        }
    }

    /// `-c` · `--config-env` 값(`키=…`)이 위험한 설정이면 그 키. 별칭 · 원격 명령(upload/receive pack, ssh) · 훅 경로 ·
    /// 원격 주소 · push 대상 바꾸기 · 설정 포함 · 프로토콜 허용 · 자격 증명.
    static func dangerousConfigKey(_ value: String) -> String? {
        let key = (value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value).lowercased()
        let exact: Set<String> = ["core.sshcommand", "core.hookspath", "core.gitproxy", "core.fsmonitor", "core.askpass"]
        let prefixes = ["alias.", "url.", "include.", "includeif.", "protocol.", "credential.", "remote."]
        let suffixes = [".uploadpack", ".receivepack"]
        if exact.contains(key) || prefixes.contains(where: key.hasPrefix) || suffixes.contains(where: key.hasSuffix) { return key }
        return nil
    }

    /// 보안 리뷰 C-2 — `--upload-pack <명령>` 은 allow(`git fetch`) 로 샌드박스 밖에서 임의 명령을 돌린다. 정형 모양이 없다.
    private static func fetchDanger(_ args: [String]) -> Danger? {
        for t in args {
            if t == "--" { break }
            if isLongOption(t, abbreviating: ["--upload-pack"]) {
                return Danger(reason: "fetch --upload-pack(원격 쪽 명령 바꾸기)", example: "git fetch origin", kind: .rewrite)
            }
        }
        return nil
    }

    /// allow 모양 push 에 받는 옵션(정확한 이름만, 줄임 없음). 이 밖의 옵션은 값이 브랜치 자리를 먹을 수 있어 막는다(보안 리뷰 C-1).
    static let pushKnownOptions: Set<String> = [
        "-u", "--set-upstream", "-q", "--quiet", "-v", "--verbose", "-n", "--dry-run", "--no-verify",
        "--progress", "--porcelain", "--atomic", "--follow-tags",
    ]

    private static func pushDanger(_ args: [String]) -> Danger? {
        let force = Danger(reason: "force push", example: "git push --force origin <브랜치>")
        var positionals: [String] = []
        var found: Danger?
        var unknown: String?
        var i = 0
        let n = args.count
        var onlyPositional = false
        func note(_ d: Danger) { if found == nil { found = d } }
        while i < n {
            let t = args[i]
            i += 1
            if onlyPositional || !t.hasPrefix("-") || t == "-" {
                positionals.append(t); continue
            }
            if t == "--" { onlyPositional = true; continue }
            if t.hasPrefix("--") {
                if t.hasPrefix("--force-w"), isLongOption(t, abbreviating: ["--force-with-lease"]) {
                    note(Danger(reason: "force push", example: "git push --force-with-lease origin <브랜치>"))
                } else if isLongOption(t, abbreviating: ["--force", "--force-if-includes"]) {
                    note(force)
                } else if isLongOption(t, abbreviating: ["--delete"]) {
                    note(Danger(reason: "원격 브랜치 삭제 push", example: "git push origin --delete <브랜치>"))
                } else if let flag = ["--mirror", "--prune", "--all", "--branches", "--tags"].first(where: { isLongOption(t, abbreviating: [$0]) }) {
                    let shown = flag == "--branches" ? "--all" : flag
                    note(Danger(reason: "\(shown) push", example: "git push origin \(shown)"))
                } else if pushKnownOptions.contains(t) || t.hasPrefix("--push-option=") {
                    continue
                } else if t == "--push-option" {
                    i += 1
                } else if unknown == nil {
                    unknown = t
                }
                continue
            }
            // 짧은 옵션 묶음(-fu · -uq · -d …). -o 는 값을 받는다(붙어 있으면 나머지가 값).
            for (k, ch) in t.dropFirst().enumerated() {
                if ch == "f" { note(force); continue }
                if ch == "d" { note(Danger(reason: "원격 브랜치 삭제 push", example: "git push origin --delete <브랜치>")); continue }
                if "uqvn".contains(ch) { continue }
                if ch == "o" {
                    if k == t.count - 2 { i += 1 }
                    break
                }
                if unknown == nil { unknown = t }
                break
            }
        }
        if let unknown {
            return Danger(reason: "모르는 push 옵션(\(unknown))",
                          example: "git push -u origin <브랜치 이름> (옵션은 -u · -q · -v · -n · --dry-run · --no-verify · --progress · "
                              + "--porcelain · --atomic · --follow-tags · -o <값> 만)",
                          kind: .rewrite)
        }
        if let found { return found }
        if positionals.count < 2 {
            return Danger(reason: "브랜치 없는 push", example: "git push -u origin <브랜치 이름>")
        }
        for spec in positionals.dropFirst() {
            if spec.hasPrefix("+") { return force }
            if spec.contains("*") {
                return Danger(reason: "패턴 refspec push", example: "git push -u origin <브랜치 이름>")
            }
            var src = spec
            var dst = spec
            if let colon = spec.firstIndex(of: ":") {
                src = String(spec[..<colon])
                dst = String(spec[spec.index(after: colon)...])
                if src.isEmpty {
                    return Danger(reason: "원격 브랜치 삭제 push(:ref)", example: "git push origin --delete <브랜치>")
                }
                if dst.isEmpty { dst = src }
            }
            var target = dst.lowercased()
            if target.hasPrefix("refs/") { target.removeFirst("refs/".count) }
            if target.hasPrefix("heads/") { target.removeFirst("heads/".count) }
            if defaultBranches.contains(target) {
                // `x:main` · `HEAD:main` 은 정형 모양이 없다 — 그 브랜치로 옮긴 뒤 이름으로 push 하는 길을 알린다
                let example = spec.contains(":")
                    ? "git switch \(target) 로 옮긴 뒤 git push origin \(target)" : "git push origin \(target)"
                return Danger(reason: "기본 브랜치(\(target)) push", example: example)
            }
            if target.isEmpty || target == "head" || target == "@" {
                return Danger(reason: "HEAD push", example: "git push -u origin <브랜치 이름>", kind: .hidesTarget)
            }
        }
        return nil
    }

    private static func branchDanger(_ args: [String]) -> Danger? {
        let delete = Danger(reason: "브랜치 삭제", example: "git branch -D <브랜치>")
        for t in args {
            if t == "--" { break }
            if isLongOption(t, abbreviating: ["--delete"]) { return delete }
            if isShortBundle(t) {
                for ch in t.dropFirst() {
                    if ch == "d" || ch == "D" { return delete }
                    if ch == "u" { break }
                }
            }
        }
        return nil
    }

    private static func switchDanger(_ args: [String]) -> Danger? {
        for t in args {
            if t == "--" { break }
            if isLongOption(t, abbreviating: ["--force", "--discard-changes"]) {
                return Danger(reason: "switch 강제(작업 버리기)", example: "git switch --force <브랜치>")
            }
            if isLongOption(t, abbreviating: ["--force-create"]) {
                return Danger(reason: "브랜치 덮기(switch -C)", example: "git switch -C <브랜치>")
            }
            if isShortBundle(t) {
                for ch in t.dropFirst() {
                    if ch == "f" { return Danger(reason: "switch 강제(작업 버리기)", example: "git switch --force <브랜치>") }
                    if ch == "C" { return Danger(reason: "브랜치 덮기(switch -C)", example: "git switch -C <브랜치>") }
                    if ch == "c" { break }
                }
            }
        }
        return nil
    }

    private static let commitValuedLong: Set<String> = [
        "--message", "--file", "--reuse-message", "--reedit-message", "--fixup", "--squash", "--author", "--date",
        "--template", "--cleanup", "--trailer", "--pathspec-from-file",
    ]

    private static func commitDanger(_ args: [String]) -> Danger? {
        var i = 0
        let n = args.count
        while i < n {
            let t = args[i]
            i += 1
            if t == "--" { break }
            if t.hasPrefix("--") {
                if isLongOption(t, abbreviating: ["--amend"]) {
                    return Danger(reason: "commit --amend", example: "git commit --amend -a --no-edit 처럼 --amend 를 commit 바로 뒤에")
                }
                if commitValuedLong.contains(t) { i += 1 }
                continue
            }
            if isShortBundle(t) {
                // -m · -F · -C · -c · -t 는 값을 받는다(붙어 있으면 나머지가 값)
                for (k, ch) in t.dropFirst().enumerated() where "mFCct".contains(ch) {
                    if k == t.count - 2 { i += 1 }
                    break
                }
            }
        }
        return nil
    }

    private static func ghDanger(_ args: [String]) -> Danger? {
        var words: [String] = []
        var i = 0
        while i < args.count, words.count < 2 {
            let t = args[i]
            i += 1
            if ["-R", "--repo", "--hostname"].contains(t) { i += 1; continue }
            if t.hasPrefix("-") { continue }
            words.append(t)
        }
        if words == ["pr", "merge"] { return Danger(reason: "gh pr merge", example: "gh pr merge <번호>") }
        return nil
    }

    // MARK: - 게이트

    enum GateDecision: Equatable {
        case pass
        case deny(String)
    }

    /// PreToolUse 게이트의 판정. 막는 이유는 모델에게 그대로 간다 — 비지 않고, 마침표로 끝나지 않는다(Codex 가 `. Command:` 를 붙인다).
    /// allow 규칙에 맞는 것으로는 막지 않는다 — allow 와 prompt 가 둘 다 맞으면 Codex 는 prompt 를 고른다(실측).
    /// 예외 하나: HEAD push(`-u origin HEAD` · `origin @`)는 prompt 가 맞아도 막는다 — 사람이 대상 브랜치를 모른 채 승인하게 된다.
    /// 브랜치 이름으로 다시 내면 작업 브랜치는 allow, 기본 브랜치는 prompt 로 간다. prompt 표의 HEAD 는 게이트가 없을 때의 뒷받침.
    static func gateDecision(_ command: String) -> GateDecision {
        let segs: [Segment]
        do {
            segs = try parse(command)
        } catch {
            return .deny("두레 게이트: 따옴표나 역슬래시가 닫히지 않아 명령을 읽을 수 없다 — 따옴표를 맞춰 다시 내라")
        }
        if hasOpaqueShell(command), let word = dangerWord(in: command) {
            return .deny("두레 게이트: 명령 치환 · bash -c · 변수 같은 안쪽을 볼 수 없는 꼴에 위험할 수 있는 git 낱말(\(word))이 있다 — "
                + "그 git · gh 명령을 따로, 값을 그대로 적은 정형 모양으로 다시 내라(예: git push --force origin <브랜치>)")
        }
        for seg in segs {
            let d = danger(seg.argv)
            if let d {
                if d.kind == .hidesTarget {
                    return .deny("두레 게이트: \(d.reason) — HEAD 는 어느 브랜치로 가는지 승인 창에 보이지 않는다. 브랜치 이름을 적어 다시 내라: \(d.example)")
                }
                if d.kind == .rewrite || !promptRuleMatches(seg.argv) {
                    return .deny("두레 게이트: \(d.reason) — 이 명령은 정형 모양으로 다시 내라: \(d.example) "
                        + "(git 앞 옵션 · 환경 변수 · 감싸는 명령 없이, 위험한 옵션을 하위 명령 바로 뒤에)")
                }
            }
            // 위험 조각, 그리고 push · fetch 는 위치 인자가 브랜치를 정한다 — 셸이 펼치는 글자가 있으면 막는다(보안 리뷰 I-1)
            if d != nil || isPushOrFetch(seg.argv), let w = seg.words.first(where: \.unquotedSpecial) {
                let why = d?.reason ?? "git push · fetch"
                return .deny("두레 게이트: \(why) — 따옴표 밖 ~ ^ { } ? [ ] * 나 역슬래시가 든 인자(\(w.text))는 권한 규칙이 건너뛰거나 "
                    + "셸이 다른 이름으로 펼친다. 그 인자를 작은따옴표로 감싸라(예: git reset --hard 'HEAD~1')")
            }
        }
        return .pass
    }
}
