import Foundation
import GRDB

/// 트랜스크립트 증분 파싱 위치. 부록 A4.
/// 이벤트 쪽에는 커서가 없다 — 파일이 남아 있으면 미소비다 (A2 v6).
struct ReadCursor: Codable, FetchableRecord, PersistableRecord {
    var path: String
    var byteOffset: Int
    var lineNo: Int
    var updatedAt: Int

    static let databaseTableName = "read_cursor"
    enum CodingKeys: String, CodingKey {
        case path
        case byteOffset = "byte_offset"
        case lineNo = "line_no"
        case updatedAt = "updated_at"
    }
}

/// API 응답 하나의 사용량. 부록 A7-1.
///
/// **PK 가 `(cc_session_id, message_id)` 다. 부록 A4 의 `line_no` 가 아니다.**
/// 한 응답이 content 블록 개수만큼 여러 줄로 기록되고 **각 줄이 usage 를 통째로 복사해
/// 갖는다** (실측: 한 응답이 2~4줄). 줄 단위로 저장하면 그냥 더했을 때 약 2배가 된다.
/// A4 는 `message_id` 컬럼을 두지 않아 **저장된 데이터로는 A7-1 의 중복 제거를 할 수가 없다.**
/// `message_id` 를 키로 잡으면 같은 응답의 둘째·셋째 줄이 같은 행을 덮어써서
/// 중복이 **구조적으로** 불가능해진다. 잊어버릴 수 있는 규칙을 스키마로 옮긴 것이다.
struct TokenUsage: Codable, FetchableRecord, PersistableRecord {
    var ccSessionId: String
    var messageId: String
    /// 디버깅용. 어느 줄에서 처음 봤는지.
    var lineNo: Int
    var ts: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreation: Int
    /// A7-1 — 실측에서 output 의 41% 가 thinking 이었다. 툴팁에 쓴다.
    var thinking: Int
    var serviceTier: String?
    var model: String?

    static let databaseTableName = "token_usage"
    enum CodingKeys: String, CodingKey {
        case ccSessionId = "cc_session_id"
        case messageId = "message_id"
        case lineNo = "line_no"
        case ts, input, output, thinking, model
        case cacheRead = "cache_read"
        case cacheCreation = "cache_creation"
        case serviceTier = "service_tier"
    }

    /// A7-1 표시 정책 — 실제로 비싸게 청구되는 부분.
    /// `cache_read` 는 **일부러 빼고** 따로 흐리게 보여준다 (입력의 97%를 차지해 헤드라인을 왜곡한다).
    var headline: Int { input + cacheCreation + output }
}

/// 툴 호출 하나. 부록 A7-2.
/// PK 가 `(cc_session_id, line_no)` 인 것은 **실측 근거가 있다** —
/// 트랜스크립트 25개에서 한 줄에 `tool_use` 블록이 2개 이상인 사례가 0건이다.
/// content 블록 하나가 곧 한 줄이기 때문이다.
struct ToolUse: Codable, FetchableRecord, PersistableRecord {
    var ccSessionId: String
    var lineNo: Int
    var ts: Int
    var toolName: String
    /// `mcp__<서버>__<툴>` 의 2번째 조각. 3조각이 아니면 **추측하지 않고 nil** (A7-2).
    var mcpServer: String?
    /// `plugin:skill` 형태 그대로. 쪼개지 않는다.
    var skillName: String?

    static let databaseTableName = "tool_use"
    enum CodingKeys: String, CodingKey {
        case ccSessionId = "cc_session_id"
        case lineNo = "line_no"
        case ts
        case toolName = "tool_name"
        case mcpServer = "mcp_server"
        case skillName = "skill_name"
    }
}
