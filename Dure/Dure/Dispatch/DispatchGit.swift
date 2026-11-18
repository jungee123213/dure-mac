import Foundation

/// 배분의 git 작업 방식. 이슈 번호를 새로 만들지(`newIssue`) 기존 이슈의 브랜치를 이어 갈지(`continueWork`).
/// git 을 안 쓰는 배분은 `Dispatch.gitMode == nil` 이다.
enum GitMode: String, Codable {
    case newIssue = "new_issue"
    case continueWork = "continue"
}

/// 에이전트가 어디까지 하는가 — 커밋까지(`commit`) 또는 PR 까지(`pr`).
enum GitScope: String, Codable {
    case commit, pr
}

/// `dispatch` 툴 인자에서 읽은 git 요청. `mode == nil` 이면 git 을 안 쓰는 배분.
nonisolated struct DispatchGitRequest: Equatable {
    var mode: GitMode?
    var issueTitle: String?
    var issueBody: String?
    var branchHint: String?
    var baseBranch: String?
    var branch: String?
    var issueNumber: Int?
    var scope: GitScope?

    static let none = DispatchGitRequest()
}

/// `complete` 가 실어 온 결과 값. 못 읽는 값은 nil.
nonisolated struct DispatchCompletion: Equatable {
    var issueNumber: Int?
    var branch: String?
    var prNumber: Int?
}

nonisolated enum DispatchGitError: Error, Equatable {
    case titleAndIssue, emptyBody, bodyWithoutTitle, continueNeedsBranch, badIssue, badScope, baseOnContinue

    /// 모델이 읽는 한 줄 — 무엇이 틀렸고 어떻게 고치나.
    var message: String {
        switch self {
        case .titleAndIssue: "issue_title 과 issue 는 함께 줄 수 없다 — 새 이슈면 issue_title+issue_body, 이어 하기면 issue+branch"
        case .emptyBody: "issue_title 이 있으면 issue_body 도 줘야 한다 — 이슈 본문을 채워 다시 부른다"
        case .bodyWithoutTitle: "issue_body 는 issue_title 과 함께 준다 — 새 이슈면 issue_title 을 채우고, 이어 하기 · git 없음이면 issue_body 를 빼고 다시 부른다"
        case .continueNeedsBranch: "issue 로 이어 하려면 branch 도 줘야 한다 — 이어 갈 브랜치 이름을 채워 다시 부른다"
        case .badIssue: "issue 는 이슈 번호(165 · #165 · 이슈 URL)여야 한다 — 숫자로 고쳐 다시 부른다"
        case .badScope: "git_scope 는 commit 또는 pr 이어야 한다 — 둘 중 하나로 고쳐 다시 부른다"
        case .baseOnContinue: "base 는 새 이슈에서만 쓴다 — 이어 하기에서는 빼고 다시 부른다"
        }
    }
}

nonisolated enum DispatchGit {

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func request(from args: [String: String]) -> Result<DispatchGitRequest, DispatchGitError> {
        let title = clean(args["issue_title"])
        let issue = clean(args["issue"])
        // 제목 없는 본문 — 그냥 두면 git 없음 · 이어 하기로 떨어져 조율자가 쓴 초안이 소리 없이 사라진다.
        if title == nil, clean(args["issue_body"]) != nil { return .failure(.bodyWithoutTitle) }
        if title == nil && issue == nil { return .success(.none) }
        if title != nil && issue != nil { return .failure(.titleAndIssue) }

        let scope: GitScope
        if let raw = clean(args["git_scope"]) {
            guard let s = GitScope(rawValue: raw) else { return .failure(.badScope) }
            scope = s
        } else { scope = .commit }

        var r = DispatchGitRequest()
        r.scope = scope
        if let title {
            guard let body = clean(args["issue_body"]) else { return .failure(.emptyBody) }
            r.mode = .newIssue
            r.issueTitle = title
            r.issueBody = body
            r.branchHint = clean(args["branch"])
            r.baseBranch = clean(args["base"])
        } else {
            guard let n = number(issue) else { return .failure(.badIssue) }
            guard let branch = clean(args["branch"]) else { return .failure(.continueNeedsBranch) }
            if clean(args["base"]) != nil { return .failure(.baseOnContinue) }
            r.mode = .continueWork
            r.issueNumber = n
            r.branch = branch
        }
        return .success(r)
    }

    /// `165` · `#165` · 이슈/PR URL → 숫자.
    static func number(_ raw: String?) -> Int? {
        guard var s = clean(raw) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if let n = Int(s), n > 0, s.allSatisfy(\.isNumber) { return n }
        guard let m = s.firstMatch(of: /\/(?:issues|pull)\/(\d+)/), let n = Int(m.1), n > 0 else { return nil }
        return n
    }

    static func completion(from args: [String: String]) -> DispatchCompletion {
        DispatchCompletion(issueNumber: number(args["issue"]), branch: clean(args["branch"]), prNumber: number(args["pr"]))
    }

    static func completionNote(_ d: Dispatch, _ c: DispatchCompletion) -> String? {
        var parts: [String] = []
        if let n = c.issueNumber { parts.append("이슈 #\(n)") }
        if let b = c.branch { parts.append("브랜치 \(b)") }
        if let p = c.prNumber { parts.append("PR #\(p)") }
        if d.gitMode == .newIssue, c.issueNumber == nil { parts.append("⚠️ 이슈 번호 없음") }
        if d.gitMode == .continueWork, let b = c.branch, b != d.branch {
            parts.append("⚠️ 브랜치가 지시(\(d.branch ?? "-"))와 다름")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
