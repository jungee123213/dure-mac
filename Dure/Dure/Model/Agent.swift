import Foundation
import GRDB

/// 터미널(PTY) 하나 = 에이전트 하나. 앱이 만든 `DURE_SESSION` UUID 가 여기 산다.
/// 부록 A4.
struct Agent: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var dureSession: String
    var repoId: String
    /// D-3 — claude / codex. 이벤트 줄에도 같은 값이 실린다.
    var agentKind: String
    /// started|running|waiting|done|dead. **전이는 Step 6(F4) 에서 한다.**
    /// Step 4 는 매핑만 만들고 상태는 `started` 로 두고 건드리지 않는다.
    var state: String
    var model: String?
    var startedAt: Int
    var endedAt: Int?

    var id: String { dureSession }
    static let databaseTableName = "agent"

    enum CodingKeys: String, CodingKey {
        case dureSession = "dure_session"
        case repoId = "repo_id"
        case agentKind = "agent_kind"
        case state, model
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

/// ADR-17 의 브리지. 에이전트 1 : cc_session N 이다.
/// 터미널 하나 안에서도 `/clear`·`/compact`·`--resume` 이 새 sessionId 를 만들고
/// `SessionStart` 가 다시 발화한다 (Step 0-E, Step 3 실측 모두 확인).
/// 앱 UUID 를 PK 로 잡으면 두 번째 `SessionStart` 에서 앞선 트랜스크립트의 토큰이 유실된다.
struct CCSession: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var ccSessionId: String
    var dureSession: String
    /// F6·F7 이 읽을 파일. **슬러그 추측 금지** — 훅이 정확한 경로를 준다 (ADR-17).
    var transcriptPath: String
    var source: String
    var model: String?
    var startedAt: Int

    var id: String { ccSessionId }
    static let databaseTableName = "cc_session"

    enum CodingKeys: String, CodingKey {
        case ccSessionId = "cc_session_id"
        case dureSession = "dure_session"
        case transcriptPath = "transcript_path"
        case source, model
        case startedAt = "started_at"
    }
}
