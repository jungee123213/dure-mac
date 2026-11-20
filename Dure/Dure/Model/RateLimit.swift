import Foundation
import GRDB

/// 사용 한도 창 하나의 마지막 값(v10 `rate_limit`). 키 `(kind, window)` — 같은 창은 덮어쓴다.
struct RateLimitWindow: Codable, FetchableRecord, PersistableRecord, Equatable {
    /// 지금은 `"codex"` 뿐.
    var kind: String
    /// `"primary"` · `"secondary"`
    var window: String
    var usedPercent: Int
    var windowMinutes: Int?
    var resetsAt: Int?
    var planType: String?
    var reachedType: String?
    var seenAt: Int

    static let databaseTableName = "rate_limit"
    static let persistenceConflictPolicy = PersistenceConflictPolicy(insert: .replace, update: .replace)
    enum CodingKeys: String, CodingKey {
        case kind, window
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
        case planType = "plan_type"
        case reachedType = "reached_type"
        case seenAt = "seen_at"
    }
}

/// `account/rateLimits/read` · `account/rateLimits/updated` 에서 읽은 Codex 한도.
/// 알림은 희소하다(실측 j-stage4 1절) — 칸이 `nil` 이면 "모름, 이전 값 그대로"다. 그래서 모든 칸이 선택값이다.
nonisolated struct CodexRateLimits: Equatable {
    struct Window: Equatable {
        var usedPercent: Int
        var windowMinutes: Int?
        var resetsAt: Int?
    }

    var primary: Window?
    var secondary: Window?
    var planType: String?
    var reachedType: String?
    /// `read` 응답에만 있다.
    var ordinaryUsageAllowed: Bool?

    /// 창은 통째로 합친다 — `nil` 아닌 창이 이전 창을 바꾸고 `nil` 이면 이전 창을 둔다. 그 밖의 `nil` 칸도 이전 값을 둔다. `reachedType` 이 `nil` 이어도 풀림이 아니다 — 풀림은 `read` 응답으로만 판정한다.
    func merged(into previous: CodexRateLimits?) -> CodexRateLimits {
        CodexRateLimits(primary: primary ?? previous?.primary,
                        secondary: secondary ?? previous?.secondary,
                        planType: planType ?? previous?.planType,
                        reachedType: reachedType ?? previous?.reachedType,
                        ordinaryUsageAllowed: ordinaryUsageAllowed ?? previous?.ordinaryUsageAllowed)
    }
}
