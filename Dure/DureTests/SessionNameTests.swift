import Foundation
import Testing
@testable import Dure

/// 이슈 #16 — `claude --name`. 조율자가 "같은 워크스페이스 세션" 을 이름 접두사로 고른다 (D-31).
struct SessionNameTests {

    @Test(arguments: [
        ("모바일 로그인 개편", "모바일-로그인-개편"),
        ("api/server", "apiserver"),
        ("  앞뒤  공백 ", "앞뒤-공백"),
        ("🚀 런치", "런치"),
        ("a__b--c", "a__b-c"),
    ])
    func 슬러그는_멘션에_쓸_수_있는_글자만_남긴다(_ input: String, _ expected: String) {
        #expect(SessionName.slug(input) == expected)
    }

    @Test func 빈_슬러그는_자리표시로_채운다() {
        #expect(SessionName.slug("!!!") == "x")
    }

    @Test func 짧은_아이디는_UUID_앞_4자_소문자다() {
        #expect(SessionName.shortID("7F3A9C21-0000-0000-0000-000000000000") == "7f3a")
    }

    @Test func 레포_페인_이름() {
        #expect(SessionName.repo(workspaceName: "모바일", workspaceID: "7F3A-1",
                                 repoName: "MoaMap") == "dure-모바일-7f3a-MoaMap")
    }

    @Test func 조율자_이름() {
        #expect(SessionName.orchestrator(workspaceName: "모바일", workspaceID: "7F3A-1")
                == "dure-모바일-7f3a-조율자")
    }

    /// Review Focus 4 — 이름이 같은 워크스페이스 둘은 접두사가 달라야 한다.
    @Test func 이름이_같아도_워크스페이스가_다르면_접두사가_다르다() {
        let a = SessionName.prefix(workspaceName: "앱", workspaceID: "aaaa-1")
        let b = SessionName.prefix(workspaceName: "앱", workspaceID: "bbbb-2")
        #expect(a != b)
        #expect(!SessionName.repo(workspaceName: "앱", workspaceID: "aaaa-1", repoName: "x").hasPrefix(b))
    }
}
