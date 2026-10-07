import Foundation
import Testing
@testable import Dure

/// 이슈 #16 — 조율자의 `CLAUDE.md`. 조율자가 지키는 규칙은 **이 문서가 전부**다
/// (메시지 범위는 Claude Code 가 강제하지 못한다, D-31).
struct OrchestratorDocTests {

    static let md = OrchestratorDoc.render(
        workspaceName: "모바일", sessionPrefix: "dure-모바일-7f3a-",
        repos: [.init(name: "back", path: "/a/back"), .init(name: "ios", path: "/a/my ios")])

    @Test func 자동_생성_문서라고_밝힌다() {
        #expect(Self.md.contains("자동으로 만든다"))
        #expect(Self.md.contains("context.md"))
    }

    @Test func 먼저_읽을_문서를_적는다() {
        #expect(Self.md.contains("workspace.md"))
    }

    /// 허용 규칙(Task 3)과 **같은 모양**이어야 승인 없이 실행된다.
    @Test func git_읽기_명령을_허용된_모양_그대로_적는다() {
        #expect(Self.md.contains("git -C /a/back log"))
        #expect(Self.md.contains("git -C '/a/my ios' log"))
    }

    @Test func git_쓰기와_cd_형태를_금지한다() {
        #expect(Self.md.contains("커밋"))
        #expect(Self.md.contains("cd"))
    }

    /// `--output=<파일>` 은 git 이 파일을 쓴다. 설정이 막으므로 에이전트가 시도하지 않게 알린다.
    @Test func output_옵션을_쓰지_말라고_적는다() {
        #expect(Self.md.contains("--output"))
    }

    @Test func 메시지는_접두사로_시작하는_세션에만() {
        #expect(Self.md.contains("dure-모바일-7f3a-"))
    }

    @Test func 레포가_없어도_만든다() {
        let md = OrchestratorDoc.render(workspaceName: "빈", sessionPrefix: "dure-빈-0000-", repos: [])
        #expect(md.contains("등록된 레포가 없다"))
    }
}
