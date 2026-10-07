import Foundation
import Testing
@testable import Dure

/// Step 7 · F8 git 상태 읽기.
/// **순수 파싱만 여기서 본다** — 프로세스 실행은 `GitReader` 쪽이다.
struct GitStatusTests {

    // MARK: - dirty 세기 (D-14)

    /// `git status --porcelain` 은 줄 끝마다 개행을 붙인다.
    /// 그냥 쪼개면 마지막 빈 줄까지 세어 항상 +1 이 된다.
    @Test func 끝의_개행을_한_줄로_세지_않는다() {
        let porcelain = " M Dure/Dure/Model/Agent.swift\n?? docs/NOTES.md\n"
        #expect(GitStatusParser.parse(branch: "dev", porcelain: porcelain).dirtyCount == 2)
    }

    @Test func 출력이_비면_clean_이다() {
        let status = GitStatusParser.parse(branch: "dev", porcelain: "")
        #expect(status.dirtyCount == 0)
        #expect(status.isClean)
    }

    /// D-14 — 새로 만든 파일은 `git add` 전까지 `??` 다. 두레는 git 에 쓰지 않으므로
    /// 에이전트가 만든 파일은 계속 untracked 로 남는다. 빼면 "새 파일만 만든 에이전트"가
    /// clean 으로 보인다.
    @Test func untracked_도_dirty_로_센다() {
        let porcelain = "?? Dure/Dure/Git/GitReader.swift\n?? docs/STEP7.md\n"
        #expect(GitStatusParser.parse(branch: "dev", porcelain: porcelain).dirtyCount == 2)
    }

    @Test func staged_와_unstaged_를_가리지_않는다() {
        let porcelain = "A  New.swift\n M Old.swift\n D Gone.swift\nR  A.swift -> B.swift\n"
        #expect(GitStatusParser.parse(branch: "dev", porcelain: porcelain).dirtyCount == 4)
    }

    // MARK: - 브랜치

    @Test func 브랜치명의_공백을_턴다() {
        #expect(GitStatusParser.parse(branch: "feat/#7/git\n", porcelain: "").branch == "feat/#7/git")
    }

    /// detached HEAD 면 `rev-parse --abbrev-ref` 가 문자열 "HEAD" 를 준다.
    /// 그대로 띄우면 브랜치 이름이 HEAD 인 것처럼 보인다.
    @Test func detached_HEAD_를_브랜치명으로_착각하지_않는다() {
        let status = GitStatusParser.parse(branch: "HEAD", porcelain: "")
        #expect(status.isDetached)
    }

    @Test func 보통_브랜치는_detached_가_아니다() {
        #expect(!GitStatusParser.parse(branch: "dev", porcelain: "").isDetached)
    }
}

/// `GitReader` 는 진짜 `git` 을 부른다. 임시 레포를 만들어 실물로 확인한다 —
/// D-14(untracked 포함)는 **파싱이 아니라 git 의 실제 출력**에 걸린 문제라
/// 문자열을 손으로 넣는 테스트로는 고정되지 않는다.
struct GitReaderTests {

    /// 커밋 하나 있는 임시 레포를 만든다.
    static func makeRepo() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dure-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("init", "-b", "main", in: dir)
        try run("config", "user.email", "t@t.t", in: dir)
        try run("config", "user.name", "t", in: dir)
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("add", ".", in: dir)
        try run("commit", "-m", "init", in: dir)
        return dir
    }

    @discardableResult
    static func run(_ args: String..., in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    @Test func 브랜치명을_읽는다() throws {
        let repo = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let status = try #require(GitReader.read(at: repo.path))
        #expect(status.branch == "main")
        #expect(status.isClean)
    }

    /// D-14 를 실물로 못박는다. `git add` 없이 파일만 만들어도 잡혀야 한다.
    @Test func add_하지_않은_새_파일도_센다() throws {
        let repo = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "새로 만든 파일".write(to: repo.appendingPathComponent("New.swift"),
                              atomically: true, encoding: .utf8)

        let status = try #require(GitReader.read(at: repo.path))
        #expect(status.dirtyCount == 1)
        #expect(!status.isClean)
    }

    /// `.gitignore` 가 거른 파일은 세지 않는다. 안 그러면 빌드 산출물로 숫자가 부푼다.
    @Test func gitignore_된_파일은_세지_않는다() throws {
        let repo = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "*.log\n".write(to: repo.appendingPathComponent(".gitignore"),
                            atomically: true, encoding: .utf8)
        try "시끄러움".write(to: repo.appendingPathComponent("build.log"),
                         atomically: true, encoding: .utf8)

        let status = try #require(GitReader.read(at: repo.path))
        // .gitignore 자신만 잡힌다. build.log 는 아니다.
        #expect(status.dirtyCount == 1)
    }

    /// D-13 — 갱신 실패는 상태를 지우지 않는다. 없는 것을 `clean` 으로 보이면 거짓말이다.
    @Test func 레포가_아니면_nil_이다() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dure-notrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(GitReader.read(at: dir.path) == nil)
    }

    @Test func 없는_경로면_nil_이다() {
        #expect(GitReader.read(at: "/그런/폴더는/없다") == nil)
    }
}

/// D-13 의 "갱신 실패는 상태를 지우지 않는다" 를 고정한다.
/// **조용히 틀리는 종류다** — 화면에 `clean` 이 떠 있으면 그게 방금 읽은 값인지
/// 못 읽어서 비워진 값인지 눈으로 구별할 수 없다.
struct GitStatusCacheTests {

    static let dirty = GitStatus(branch: "dev", dirtyCount: 3, isDetached: false)

    @Test func 읽기에_성공하면_갱신한다() {
        var cache = GitStatusCache()
        cache.update("repo-1", with: Self.dirty)
        #expect(cache["repo-1"] == Self.dirty)
    }

    @Test func 읽기에_실패하면_마지막_값을_유지한다() {
        var cache = GitStatusCache()
        cache.update("repo-1", with: Self.dirty)
        cache.update("repo-1", with: nil)
        #expect(cache["repo-1"] == Self.dirty)
    }

    /// 못 읽은 것을 `clean` 으로 채우면 거짓말이 된다. 아무것도 없어야 한다.
    @Test func 한_번도_못_읽었으면_비어_있다() {
        var cache = GitStatusCache()
        cache.update("repo-1", with: nil)
        #expect(cache["repo-1"] == nil)
    }

    @Test func 레포끼리_섞이지_않는다() {
        var cache = GitStatusCache()
        cache.update("repo-1", with: Self.dirty)
        cache.update("repo-2", with: GitStatus(branch: "main", dirtyCount: 0, isDetached: false))
        #expect(cache["repo-1"]?.branch == "dev")
        #expect(cache["repo-2"]?.branch == "main")
    }
}

/// D-13 — `Stop` 은 "에이전트가 방금 파일을 건드렸을" 시점이라 git 을 다시 읽는다.
struct GitRefreshTriggerTests {

    @Test func Stop_은_git_을_다시_읽게_한다() throws {
        let r = AgentStateMachine.reaction(to: try AgentStateTests.event("Stop"), current: .running)
        #expect(r.refreshGit)
    }

    /// 매 훅마다 프로세스를 띄우면 낭비다. 파일이 바뀌었을 리 없는 이벤트는 건너뛴다.
    @Test func 나머지_훅은_git_을_읽지_않는다() throws {
        #expect(!AgentStateMachine.reaction(to: try AgentStateTests.event("UserPromptSubmit"), current: .started).refreshGit)
        #expect(!AgentStateMachine.reaction(to: try AgentStateTests.event("SessionStart"), current: nil).refreshGit)
    }

    /// 죽은 페인은 이미 무시된다. git 만 예외로 새는 일이 없어야 한다 (D-12).
    @Test func 죽은_페인은_git_도_읽지_않는다() throws {
        #expect(!AgentStateMachine.reaction(to: try AgentStateTests.event("Stop"), current: .dead).refreshGit)
    }
}

/// 설계문서 4절 — `workspace.md` 의 "최근 커밋 5줄".
/// 조율자가 "백엔드에 뭐가 바뀌었나" 를 읽는 값이다.
struct GitLogTests {

    @Test func 로그를_줄_단위로_쪼갠다() {
        let log = "a1b2c3d 로그인 응답에 refreshToken 추가\ne4f5g6h 에러 코드 정리\n"
        let s = GitStatusParser.parse(branch: "dev", porcelain: "", log: log)
        #expect(s.recentCommits == ["a1b2c3d 로그인 응답에 refreshToken 추가",
                                    "e4f5g6h 에러 코드 정리"])
    }

    @Test func 로그가_비면_빈_배열이다() {
        #expect(GitStatusParser.parse(branch: "dev", porcelain: "", log: "").recentCommits.isEmpty)
    }

    /// 기존 호출부를 깨지 않는다. `log` 는 기본값이 있다.
    @Test func log_없이_불러도_된다() {
        #expect(GitStatusParser.parse(branch: "dev", porcelain: "").recentCommits.isEmpty)
    }

    @Test func 실제_레포에서_커밋_메시지를_읽는다() throws {
        let repo = try GitReaderTests.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let s = try #require(GitReader.read(at: repo.path))
        #expect(s.recentCommits.count == 1)
        #expect(s.recentCommits[0].hasSuffix("init"))
    }

    /// 최종 리뷰 F7 — 사용자 설정(`log.decorate`, `color.ui=always`)이 `workspace.md` 에
    /// `(HEAD -> main)` 이나 ANSI 이스케이프를 섞으면 안 된다.
    @Test func 사용자_git_설정이_로그를_오염시키지_않는다() throws {
        let repo = try GitReaderTests.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try GitReaderTests.run("config", "log.decorate", "short", in: repo)
        try GitReaderTests.run("config", "color.ui", "always", in: repo)

        let s = try #require(GitReader.read(at: repo.path))
        #expect(s.recentCommits.count == 1)
        #expect(!s.recentCommits[0].contains("HEAD"))
        #expect(!s.recentCommits[0].contains("\u{1B}"))
    }

    /// **커밋이 하나도 없는 레포에서 `git log` 는 실패한다.**
    /// 그것 때문에 상태 전체가 nil 이 되면 브랜치도 dirty 도 못 보게 된다.
    @Test func 커밋이_없어도_상태를_돌려준다() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dure-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try GitReaderTests.run("init", "-b", "main", in: dir)

        let s = try #require(GitReader.read(at: dir.path))
        #expect(s.recentCommits.isEmpty)
        #expect(s.branch == "main")
    }
}
