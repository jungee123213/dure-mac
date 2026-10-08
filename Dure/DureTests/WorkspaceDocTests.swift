import Foundation
import Testing
@testable import Dure

/// 조율자 설계 단계 1 · `workspace.md` 생성.
/// **조율자가 읽을 문서라 "모르는 것" 과 "없는 것" 이 구별돼야 한다** — git 을 못 읽은 것과
/// 변경이 없는 것은 다르다 (D-13).
struct WorkspaceDocTests {

    static func line(_ name: String,
                     role: String? = nil,
                     git: GitStatus? = nil,
                     openedWith: AgentKind? = nil) -> WorkspaceDoc.RepoLine {
        WorkspaceDoc.RepoLine(name: name, path: "/repos/\(name)",
                              role: role, git: git, openedWith: openedWith)
    }

    @Test func 워크스페이스_이름이_제목에_들어간다() {
        let md = WorkspaceDoc.render(name: "모바일 개편", repos: [])
        #expect(md.contains("모바일 개편"))
    }

    @Test func 레포_이름과_경로가_들어간다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("android")])
        #expect(md.contains("android"))
        #expect(md.contains("/repos/android"))
    }

    @Test func 역할이_있으면_적고_없으면_생략한다() {
        let withRole = WorkspaceDoc.render(name: "ws", repos: [Self.line("backend", role: "API 서버")])
        #expect(withRole.contains("API 서버"))

        let without = WorkspaceDoc.render(name: "ws", repos: [Self.line("backend")])
        #expect(!without.contains("역할"))
    }

    @Test func 브랜치와_변경_수를_적는다() {
        let git = GitStatus(branch: "feat/login", dirtyCount: 3,
                            isDetached: false, recentCommits: [])
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("android", git: git)])
        #expect(md.contains("feat/login"))
        #expect(md.contains("3"))
    }

    @Test func 변경이_없으면_clean_이라고_적는다() {
        let git = GitStatus(branch: "main", dirtyCount: 0, isDetached: false, recentCommits: [])
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("ios", git: git)])
        #expect(md.contains("clean"))
    }

    /// **급소.** git 을 못 읽은 것을 `clean` 으로 적으면 조율자가 "변경 없음" 으로 읽는다.
    @Test func git_을_못_읽었으면_모른다고_적는다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("backend", git: nil)])
        #expect(md.contains("읽지 못함"))
        #expect(!md.contains("clean"))
    }

    @Test func 최근_커밋을_그대로_싣는다() {
        let git = GitStatus(branch: "dev", dirtyCount: 0, isDetached: false,
                            recentCommits: ["a1b2c3d refreshToken 추가", "e4f5g6h 에러 코드 정리"])
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("backend", git: git)])
        #expect(md.contains("refreshToken 추가"))
        #expect(md.contains("에러 코드 정리"))
    }

    @Test func 열린_페인은_어떤_AI_인지_적는다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("android", openedWith: .codex)])
        #expect(md.contains("codex"))
    }

    @Test func 안_열린_페인은_열려_있다고_적지_않는다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("android", openedWith: nil)])
        #expect(!md.contains("claude"))
        #expect(!md.contains("codex"))
    }

    /// 설계문서 4절 — 소유권 플래그를 두지 않는다. 문서에도 그런 말이 나오면 안 된다.
    @Test func 내_작업_남의_작업_같은_말을_쓰지_않는다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [Self.line("backend")])
        #expect(!md.contains("남의 작업"))
        #expect(!md.contains("내 작업"))
    }

    @Test func 레포가_없으면_없다고_적는다() {
        #expect(WorkspaceDoc.render(name: "ws", repos: []).contains("등록된 레포가 없습니다"))
    }

    // MARK: - #16 조율자

    @Test func 레포_지시문_경로를_적는다() {
        var l = Self.line("back")
        l.instructionsPath = "/repos/back/CLAUDE.md"
        #expect(WorkspaceDoc.render(name: "ws", repos: [l]).contains("/repos/back/CLAUDE.md"))
    }

    @Test func 세션_이름을_적는다() {
        var l = Self.line("back")
        l.sessionName = "dure-ws-abcd-back"
        #expect(WorkspaceDoc.render(name: "ws", repos: [l]).contains("dure-ws-abcd-back"))
    }

    @Test func 폴더가_없는_레포를_적는다() {
        var l = Self.line("back")
        l.folderMissing = true
        #expect(WorkspaceDoc.render(name: "ws", repos: [l]).contains("폴더 없음"))
    }

    @Test func 조율자_줄을_적는다() {
        let md = WorkspaceDoc.render(name: "ws", repos: [],
                                     orchestrator: .init(sessionName: "dure-ws-abcd-조율자", openedWith: .claude))
        #expect(md.contains("## 조율자"))
        #expect(md.contains("dure-ws-abcd-조율자"))
        #expect(md.contains("열려 있음"))
    }
}
