import Foundation
import GRDB

/// 단계 4 — 조율자가 레포 페인에 넘긴 일 하나. **이 표가 곧 큐이자 이력이다** (설계 4절).
/// `queued` 행이 큐, 나머지가 대시보드 ④ 의 과거다. 메모리 큐를 따로 두지 않는 이유는
/// 앱을 껐다 켜도 큐가 남아야 해서다.
/// 이슈 #24 — `waiting` 은 전달된 배분의 턴이 `complete` 없이 끝난 것(사람에게 묻고 멈춤). 완료가 아니다 —
/// 그 페인은 아직 그 일을 하는 중이라 다음 배분을 넣지 않고, 조율자에게 "끝남" 을 보내지 않는다.
/// 상태는 TEXT 열이라 새 값에 마이그레이션이 필요 없다.
enum DispatchState: String, Codable {
    case queued, delivered, waiting, done, failed, cancelled
}

struct Dispatch: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var workspaceId: String
    /// 워크스페이스 안 번호. 사람과 조율자가 "#7" 로 부른다.
    var seq: Int
    var repoId: String
    var title: String?
    var instruction: String
    var state: DispatchState
    /// `tools/call` 의 `claudecode/toolUseId`. 조율자 트랜스크립트와 맞춰볼 때 쓴다.
    var toolUseId: String?
    /// 어느 claude 세션(cc_session_id)이 받았나. 기동 프롬프트로 실었으면 "argv".
    var deliveredSession: String?
    /// `complete` 의 요약. 응답 대기 중에는 그 턴의 `last_assistant_message`(사람이 닫을 때 결과가 된다).
    var result: String?
    var failure: String?
    var attempts: Int = 0
    var createdAt: Int
    var deliveredAt: Int?
    var doneAt: Int?
    /// git 작업 방식. nil = git 을 안 쓰는 배분.
    var gitMode: GitMode? = nil
    var issueTitle: String? = nil
    var issueBody: String? = nil
    var gitScope: GitScope? = nil
    var branchHint: String? = nil
    var baseBranch: String? = nil
    var issueNumber: Int? = nil
    var branch: String? = nil
    var prNumber: Int? = nil

    static let databaseTableName = "dispatch"

    enum CodingKeys: String, CodingKey {
        case id, seq, title, instruction, state, result, failure, attempts
        case workspaceId = "workspace_id"
        case repoId = "repo_id"
        case toolUseId = "tool_use_id"
        case deliveredSession = "delivered_session"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case doneAt = "done_at"
        case gitMode = "git_mode"
        case issueTitle = "issue_title"
        case issueBody = "issue_body"
        case gitScope = "git_scope"
        case branchHint = "branch_hint"
        case baseBranch = "base_branch"
        case issueNumber = "issue_number"
        case branch
        case prNumber = "pr_number"
    }
}

/// 레포 페인(또는 앱)에서 조율자로 올라가는 메시지. 완료 · 보고 · 질문 · 실패.
enum RelayKind: String, Codable {
    case completion, report, question, failure
}

enum RelayState: String, Codable {
    case queued, delivered
}

struct Relay: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var workspaceId: String
    var dispatchId: String?
    var repoId: String?
    var kind: RelayKind
    /// 원문. 전달할 때 `DispatchBody` 가 머리말을 붙인다.
    var body: String
    var state: RelayState
    var createdAt: Int
    var deliveredAt: Int?

    static let databaseTableName = "relay"

    enum CodingKeys: String, CodingKey {
        case id, kind, body, state
        case workspaceId = "workspace_id"
        case dispatchId = "dispatch_id"
        case repoId = "repo_id"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
    }
}

/// 조율자가 레포 페인의 질문에 한 답. `relay`(페인 → 조율자)와 방향이 반대라 따로 둔다 (v9, 설계 2절).
enum AnswerState: String, Codable {
    case queued, delivered, failed
}

struct Answer: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var workspaceId: String
    var repoId: String
    /// 질문이 나온 배분. 지금 열린 배분이 아니다.
    var dispatchId: String?
    /// 답하는 질문(그 레포의 가장 최근 미답 질문).
    var questionId: String?
    var body: String
    var state: AnswerState
    var failure: String?
    var attempts: Int = 0
    var createdAt: Int
    var deliveredAt: Int?

    static let databaseTableName = "answer"

    enum CodingKeys: String, CodingKey {
        case id, body, state, failure, attempts
        case workspaceId = "workspace_id"
        case repoId = "repo_id"
        case dispatchId = "dispatch_id"
        case questionId = "question_id"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
    }
}
