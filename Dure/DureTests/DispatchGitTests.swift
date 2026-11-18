import Foundation
import Testing
@testable import Dure

@MainActor
struct DispatchGitTests {

    static func row(_ mode: GitMode?, branch: String? = nil) -> Dispatch {
        Dispatch(workspaceId: "w", seq: 1, repoId: "r", title: nil, instruction: "x", state: .delivered,
                 toolUseId: nil, deliveredSession: nil, result: nil, failure: nil, createdAt: 0,
                 deliveredAt: nil, doneAt: nil, gitMode: mode, branch: branch)
    }

    @Test func 이슈_제목이_있으면_새_이슈다() throws {
        let r = try DispatchGit.request(from: ["issue_title": "[FEAT] 공유", "issue_body": "본문", "branch": "feat/#N/share",
                                               "base": "feat/#9/base"]).get()
        #expect(r.mode == .newIssue)
        #expect(r.branchHint == "feat/#N/share")
        #expect(r.baseBranch == "feat/#9/base")
        #expect(r.branch == nil)
        #expect(r.scope == .commit)
    }

    @Test func 이슈_번호가_있으면_이어_하기다() throws {
        let r = try DispatchGit.request(from: ["issue": "#165", "branch": "feat/#165/share", "git_scope": "pr"]).get()
        #expect(r.mode == .continueWork)
        #expect(r.issueNumber == 165)
        #expect(r.branch == "feat/#165/share")
        #expect(r.scope == .pr)
    }

    @Test func 둘_다_없으면_git_없음이고_다른_칸은_버린다() {
        #expect(DispatchGit.request(from: ["git_scope": "pr", "branch": "x"]) == .success(.none))
    }

    @Test func 빈_문자열은_없는_것이다() {
        #expect(DispatchGit.request(from: ["issue_title": "", "issue": " ", "git_scope": ""]) == .success(.none))
    }

    @Test func 거절_일곱_가지() {
        let cases: [([String: String], DispatchGitError)] = [
            (["issue_title": "t", "issue_body": "b", "issue": "1"], .titleAndIssue),
            (["issue_title": "t"], .emptyBody),
            (["issue": "165"], .continueNeedsBranch),
            (["issue": "abc", "branch": "x"], .badIssue),
            (["issue_title": "t", "issue_body": "b", "git_scope": "merge"], .badScope),
            (["issue": "1", "branch": "x", "base": "main"], .baseOnContinue),
            // M-2 — 제목 없이 본문만 주면 git 없음(또는 이어 하기)으로 조용히 떨어져 초안이 사라진다
            (["issue_body": "b"], .bodyWithoutTitle),
            (["issue": "1", "branch": "x", "issue_body": "b"], .bodyWithoutTitle),
        ]
        for (args, err) in cases {
            #expect(DispatchGit.request(from: args) == .failure(err))
            #expect(!err.message.isEmpty)
        }
    }

    @Test func 번호는_여러_꼴을_읽는다() {
        #expect(DispatchGit.number("165") == 165)
        #expect(DispatchGit.number("#165") == 165)
        #expect(DispatchGit.number(" #165 ") == 165)
        #expect(DispatchGit.number("https://github.com/o/r/issues/165") == 165)
        #expect(DispatchGit.number("https://github.com/o/r/pull/42") == 42)
        #expect(DispatchGit.number("abc") == nil)
        #expect(DispatchGit.number(nil) == nil)
        #expect(DispatchGit.number("#") == nil)
    }

    @Test func 완료_인자는_못_읽는_값을_nil로() {
        let c = DispatchGit.completion(from: ["issue": "#5", "branch": " b ", "pr": "x"])
        #expect(c == DispatchCompletion(issueNumber: 5, branch: "b", prNumber: nil))
    }

    @Test func 완료_메모는_있는_값만_싣고_경고를_붙인다() {
        let full = DispatchCompletion(issueNumber: 165, branch: "feat/#165/x", prNumber: 42)
        #expect(DispatchGit.completionNote(Self.row(.newIssue), full) == "이슈 #165 · 브랜치 feat/#165/x · PR #42")
        #expect(DispatchGit.completionNote(Self.row(.newIssue), DispatchCompletion())?.contains("이슈 번호 없음") == true)
        let diff = DispatchGit.completionNote(Self.row(.continueWork, branch: "a"), DispatchCompletion(branch: "b"))
        #expect(diff?.contains("브랜치가 지시(a)와 다름") == true)
        let none = DispatchGit.completionNote(Self.row(nil), DispatchCompletion(issueNumber: 7, branch: "x", prNumber: nil))
        #expect(none == "이슈 #7 · 브랜치 x")
        #expect(none?.contains("⚠️") == false)
        #expect(DispatchGit.completionNote(Self.row(nil), DispatchCompletion()) == nil)
    }
}
