import Foundation
import Testing
@testable import Dure

/// Step 7 · F10a 실행 시점 브로드캐스트.
/// 설계문서 184줄 — `claude "<prompt>"` 인자로 넘긴다.
///
/// **여기서 지키려는 것은 이스케이프다.** 프롬프트는 사람이 자유롭게 쓰는 문장이라
/// 따옴표·백틱·`$`·줄바꿈이 다 들어온다. `zsh -ilc` 로 넘어가는 문자열 안에 박히므로
/// 한 글자만 새도 명령이 쪼개지거나 셸이 엉뚱한 것을 실행한다.
struct SpawnTests {

    static func script(_ prompt: String?, addDirs: [String] = []) -> String {
        Spawn.script(cwd: "/repo", sessionID: "pane-1", settingsPath: "/s/repo-pane.json",
                     sessionName: "dure-ws-abcd-repo", addDirs: addDirs, initialPrompt: prompt)
    }

    // MARK: - 붙이는가

    @Test func 프롬프트를_claude_인자로_붙인다() {
        #expect(Self.script("README 를 먼저 읽어라").hasSuffix("-- 'README 를 먼저 읽어라'"))
    }

    @Test func 프롬프트가_없으면_인자를_붙이지_않는다() {
        let bare = Self.script(nil)
        #expect(bare.hasSuffix("--name 'dure-ws-abcd-repo'"))
        #expect(!bare.contains(" -- "))
    }

    /// 빈 칸으로 시작하는 날이 더 많다. nil 과 똑같이 굴어야 한다.
    @Test func 빈_문자열은_없는_것과_같다() {
        #expect(Self.script("") == Self.script(nil))
    }

    @Test func 공백뿐인_프롬프트도_없는_것과_같다() {
        #expect(Self.script("   \n  ") == Self.script(nil))
    }

    // MARK: - 이스케이프 (급소)

    /// 작은따옴표가 그대로 새면 인용이 그 자리에서 닫히고 뒤가 명령이 된다.
    @Test func 작은따옴표를_가둔다() {
        let s = Self.script("don't stop")
        #expect(s.contains("'don'\\''t stop'"))
    }

    /// 백틱과 `$(...)` 는 작은따옴표 안에서는 실행되지 않는다. 그대로 남아야 한다.
    @Test func 명령치환을_실행되게_두지_않는다() {
        let s = Self.script("`rm -rf /` 와 $(whoami) 를 설명해라")
        #expect(s.contains("`rm -rf /` 와 $(whoami) 를 설명해라"))
        #expect(s.hasSuffix("'"))
    }

    /// `;` 로 명령을 이어붙이는 스크립트라 세미콜론이 새면 그 자리에서 잘린다.
    @Test func 세미콜론이_명령을_끊지_않는다() {
        let s = Self.script("빌드해라; 그리고 테스트해라")
        #expect(s.contains("'빌드해라; 그리고 테스트해라'"))
    }

    /// 여러 줄 브리핑은 실제로 흔하다. 작은따옴표 안에서 줄바꿈은 그대로 살아 있다.
    @Test func 줄바꿈이_든_브리핑도_한_인자다() {
        let s = Self.script("1. 로그인 개편\n2. 테스트 추가")
        #expect(s.contains("'1. 로그인 개편\n2. 테스트 추가'"))
    }

    // MARK: - 기존 조립을 깨지 않는다

    /// 모델은 앱이 정하지 않는다. 사람이 터미널에서 `/model` 이나 레포 설정으로 고른다.
    /// 앱이 `--model` 을 넘기면 그 설정을 덮어쓴다.
    @Test func 모델을_넘기지_않는다() {
        #expect(!Self.script("시작해라").contains("--model"))
        #expect(!Self.script(nil).contains("--model"))
    }

    @Test func 게이트_변수와_cd_는_그대로다() {
        let s = Self.script("브리핑")
        #expect(s.contains("export DURE_SESSION='pane-1'"))
        #expect(s.contains("cd '/repo' && exec claude"))
    }

    // MARK: - 조율자 (#16)

    @Test func add_dir_를_레포마다_붙인다() {
        let s = Self.script(nil, addDirs: ["/a/back", "/a/my ios"])
        #expect(s.contains("--add-dir '/a/back' --add-dir '/a/my ios'"))
    }

    /// `--add-dir` 는 가변 인자라 뒤의 프롬프트를 삼킨다 (2026-10-07 실측). 프롬프트는 `--` 뒤.
    @Test func 프롬프트는_add_dir_뒤의_구분자_다음에_온다() throws {
        let s = Self.script("시작해라", addDirs: ["/a/back"])
        let addAt = try #require(s.range(of: "--add-dir"))
        let sepAt = try #require(s.range(of: " -- '시작해라'"))
        #expect(addAt.upperBound < sepAt.lowerBound)
    }

    @Test func 세션_이름과_설정을_넘긴다() {
        let s = Self.script(nil)
        #expect(s.contains("--settings '/s/repo-pane.json'"))
        #expect(s.contains("--name 'dure-ws-abcd-repo'"))
    }
}

/// 문자열 비교만으로는 이스케이프가 맞는지 알 수 없다. **진짜 zsh 에 넣어본다.**
/// 조립한 인용이 셸을 통과한 뒤에도 원문 그대로여야 한다.
///
/// (RED 를 먼저 보지 못했다 — `quoted` 는 이미 있던 코드다. 회귀 그물로 넣는다.)
struct SpawnQuotingThroughShellTests {

    static func echoThroughZsh(_ s: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Spawn.shell)
        // 인용 동작은 `-c` 와 `-ilc` 가 같다. `.zshrc` 가 stdout 을 더럽히지 않도록 `-c` 를 쓴다.
        p.arguments = ["-c", "printf '%s' \(Spawn.quoted(s))"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test(arguments: [
        "README 를 먼저 읽어라",
        "don't stop",
        "`rm -rf /` 를 설명만 해라",
        "$(whoami) 와 $HOME 을 출력하지 마라",
        "빌드해라; 그리고 테스트해라",
        "따옴표 \" 와 ' 가 섞인 문장",
        "1. 로그인 개편\n2. 테스트 추가",
        "백슬래시 \\ 와 파이프 | 와 앰퍼샌드 &",
        "이모지 🚀 와 한글 자모 ㅋㅋ",
    ])
    func 셸을_통과해도_원문_그대로다(_ prompt: String) throws {
        #expect(try Self.echoThroughZsh(prompt) == prompt)
    }
}

/// 이슈 #10 — 레포 폴더가 없으면 `cd` 가 실패해도 claude 가 앱 프로세스의 cwd(`/`)에서 떴다.
/// 스크립트가 `;` 로 이어져 있어 `cd` 실패가 다음 명령을 막지 못했다.
///
/// **진짜 zsh 로 돌린다.** 문자열에 `&&` 가 있는지만 보면 인용·순서가 틀려도 통과한다.
/// 단 PATH 를 가짜 `claude` 하나뿐인 폴더로 묶는다 — 회귀하면 진짜 claude 가 `/` 에서
/// 뜨는 테스트가 되기 때문이다. `-ilc` 가 아니라 `-c` 인 이유도 같다(`.zshrc` 가 PATH 를 되살린다).
struct SpawnCdGuardTests {

    struct Run { let status: Int32; let launchedIn: String? }

    static func run(repoPath: String) throws -> Run {
        let fm = FileManager.default
        let bin = fm.temporaryDirectory.appendingPathComponent("dure-fake-bin-\(UUID().uuidString)")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bin) }
        let fake = bin.appendingPathComponent("claude")
        // 떴다면 어디서 떴는지 남긴다. 그것이 이 버그의 증상이다.
        try "#!/bin/sh\necho \"LAUNCHED:$(pwd)\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Spawn.shell)
        p.arguments = ["-c", Spawn.script(cwd: repoPath, sessionID: "pane-1", settingsPath: "/s.json", sessionName: "n")]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": NSHomeDirectory()]
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let launched = text.split(separator: "\n")
            .first { $0.hasPrefix("LAUNCHED:") }
            .map { String($0.dropFirst("LAUNCHED:".count)) }
        return Run(status: p.terminationStatus, launchedIn: launched)
    }

    /// 가짜 claude 가 받은 인자를 한 줄에 하나씩 찍는다. 인용이 셸을 통과해 그대로 도착하는지 본다.
    static func argv(addDirs: [String], prompt: String?) throws -> [String] {
        let fm = FileManager.default
        let bin = fm.temporaryDirectory.appendingPathComponent("dure-argv-\(UUID().uuidString)")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bin) }
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Spawn.shell)
        p.arguments = ["-c", Spawn.script(cwd: "/", sessionID: "s", settingsPath: "/set tings.json",
                                          sessionName: "dure-앱-abcd-조율자", addDirs: addDirs,
                                          initialPrompt: prompt)]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test func 조율자_인자가_셸을_통과해도_그대로다() throws {
        let args = try Self.argv(addDirs: ["/a/back", "/a/it's 한글"], prompt: "할 일")
        #expect(args == ["--settings", "/set tings.json", "--name", "dure-앱-abcd-조율자",
                         "--add-dir", "/a/back", "--add-dir", "/a/it's 한글", "--", "할 일"])
    }

    @Test func 폴더가_없으면_claude_를_띄우지_않는다() throws {
        let r = try Self.run(repoPath: "/nonexistent-dure-\(UUID().uuidString)")
        #expect(r.launchedIn == nil)
        #expect(r.status != 0)
    }

    /// 가드가 정상 경로까지 막으면 안 된다.
    @Test func 폴더가_있으면_그_폴더에서_띄운다() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dure repo '\(UUID().uuidString)'")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try Self.run(repoPath: dir.path)
        // macOS 임시 폴더는 /var → /private/var 심볼릭 링크라 pwd 가 다르게 나올 수 있다.
        #expect(r.launchedIn.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == dir.resolvingSymlinksInPath().path)
    }
}

/// 이슈 #10 — 사이드바 "폴더 없음" 표시와 시작 버튼 잠금의 근거.
struct RepoFolderExistsTests {

    static func repo(_ path: String) -> Repo { Repo(workspaceId: "w", path: path) }

    @Test func 있는_폴더는_있다() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.repo(dir.path).folderExists)
    }

    @Test func 없는_폴더는_없다() {
        #expect(!Self.repo("/nonexistent-dure-\(UUID().uuidString)").folderExists)
    }

    /// 같은 경로에 폴더 대신 파일이 있으면 `cd` 는 역시 실패한다.
    @Test func 파일은_폴더가_아니다() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!Self.repo(file.path).folderExists)
    }
}
