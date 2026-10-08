import Foundation
import GRDB

/// 단계 4 — 조율자가 레포 페인에 넘긴 일 하나. **이 표가 곧 큐이자 이력이다** (설계 4절).
/// `queued` 행이 큐, 나머지가 대시보드 ④ 의 과거다. 메모리 큐를 따로 두지 않는 이유는
/// 앱을 껐다 켜도 큐가 남아야 해서다.
enum DispatchState: String, Codable {
    case queued, delivered, done, failed, cancelled
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
    /// `Stop` 의 `last_assistant_message`.
    var result: String?
    var failure: String?
    var attempts: Int = 0
    var createdAt: Int
    var deliveredAt: Int?
    var doneAt: Int?

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
