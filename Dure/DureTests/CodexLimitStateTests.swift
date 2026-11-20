import Foundation
import GRDB
import Testing
@testable import Dure

/// Codex 4단계 Task 4 — 계정 한도 상태(순수 값). 막힘 · 다시 보기 · 풀림을 정한다. 풀림은 `read` 응답으로만(j-stage4 계획 영향 3-1).
struct CodexLimitStateTests {

    typealias W = CodexRateLimits.Window

    static func full(primaryReset: Int = 1000, secondaryReset: Int = 5000) -> CodexRateLimits {
        CodexRateLimits(primary: W(usedPercent: 100, windowMinutes: 300, resetsAt: primaryReset),
                        secondary: W(usedPercent: 100, windowMinutes: 10080, resetsAt: secondaryReset),
                        reachedType: "rate_limit_reached")
    }

    @Test func reachedTypeBlocksUntilLatestReset() {
        var s = CodexLimitState()
        #expect(s.observe(Self.full(), now: 100) == .blocked(until: 5000))
        #expect(s.blockedUntil == 5000)
        #expect(s.limits == Self.full())
    }

    @Test func underHundredNotBlocked() {
        var s = CodexLimitState()
        let l = CodexRateLimits(primary: W(usedPercent: 99, resetsAt: 1000), secondary: W(usedPercent: 50, resetsAt: 5000))
        #expect(s.observe(l, now: 100) == .none)
        #expect(s.blockedUntil == nil)
        #expect(s.limits == l)
    }

    @Test func ordinaryUsageFalseBlocks() {
        var s = CodexLimitState()
        let l = CodexRateLimits(primary: W(usedPercent: 40, resetsAt: 900), ordinaryUsageAllowed: false)
        // 꽉 찬 창이 없으니 리셋 시각을 모른다 — 다시 보기 간격 뒤에 본다.
        #expect(s.observe(l, now: 100) == .blocked(until: 400))
    }

    @Test func reachedTypeAloneBlocks() {
        var s = CodexLimitState()
        let l = CodexRateLimits(primary: W(usedPercent: 80, resetsAt: 900), reachedType: "rate_limit_reached")
        #expect(s.observe(l, now: 100) == .blocked(until: 400))
    }

    @Test func usageLimitHitWithoutWindowsUsesRecheck() {
        var s = CodexLimitState()
        #expect(s.usageLimitHit(now: 100) == .blocked(until: 400))
        #expect(s.blockedUntil == 400)
    }

    @Test func usageLimitHitUsesKnownFullWindowReset() {
        var s = CodexLimitState()
        let l = CodexRateLimits(primary: W(usedPercent: 100, resetsAt: 2000), secondary: W(usedPercent: 30, resetsAt: 9000))
        #expect(s.observe(l, replaces: false, now: 100) == .blocked(until: 2000))
        // 막힌 동안 두 번째 신호 — 같은 시각이면 바뀐 것이 없다.
        #expect(s.usageLimitHit(now: 110) == .none)
        #expect(s.blockedUntil == 2000)
    }

    @Test func usageLimitHitAfterUnblockedSnapshotUsesRecheck() {
        var s = CodexLimitState()
        _ = s.observe(CodexRateLimits(primary: W(usedPercent: 42, resetsAt: 2000)), now: 100)
        #expect(s.usageLimitHit(now: 100) == .blocked(until: 400))
    }

    @Test func secondHitWhileBlockedIsNone() {
        var s = CodexLimitState()
        _ = s.usageLimitHit(now: 100)
        #expect(s.usageLimitHit(now: 150) == .none)
        #expect(s.blockedUntil == 400)
    }

    @Test func releasedWhenClearAfterBlocked() {
        var s = CodexLimitState()
        _ = s.observe(Self.full(), now: 100)
        let clear = CodexRateLimits(primary: W(usedPercent: 0, resetsAt: 20000), secondary: W(usedPercent: 31, resetsAt: 90000),
                                    planType: "plus", ordinaryUsageAllowed: true)
        #expect(s.observe(clear, now: 5030) == .released)
        #expect(s.blockedUntil == nil)
        #expect(s.limits == clear)
    }

    @Test func stillBlockedAfterResetReschedules() {
        var s = CodexLimitState()
        _ = s.observe(Self.full(primaryReset: 1000, secondaryReset: 1000), now: 100)
        #expect(s.blockedUntil == 1000)
        // 리셋 시각 + 여유 뒤에 다시 읽었는데 아직 꽉 찼다 — 새 리셋 시각으로 다시 건다.
        let again = CodexRateLimits(primary: W(usedPercent: 100, resetsAt: 19000), secondary: W(usedPercent: 60, resetsAt: 90000))
        #expect(s.observe(again, now: 1030) == .rescheduled(until: 19000))
        #expect(s.blockedUntil == 19000)
    }

    /// 서버가 지난 리셋 시각을 그대로 주면 그 시각으로 걸면 곧바로 다시 읽기를 되풀이한다 — 간격 뒤로.
    @Test func pastResetUsesRecheckInterval() {
        var s = CodexLimitState()
        _ = s.observe(Self.full(primaryReset: 1000, secondaryReset: 1000), now: 100)
        #expect(s.observe(Self.full(primaryReset: 1000, secondaryReset: 1000), now: 1030) == .rescheduled(until: 1330))
    }

    @Test func noConnectionKeepsBlocked() {
        var s = CodexLimitState()
        _ = s.usageLimitHit(now: 100)
        s.recheckFailed(now: 2000)
        #expect(s.blockedUntil == 2300)
    }

    /// 희소한 `updated`(창이 null · reachedType null)는 "모름" 이다 — 막힌 상태를 풀지 않는다. 값은 합친다.
    @Test func sparseUpdateDoesNotRelease() {
        var s = CodexLimitState()
        _ = s.observe(Self.full(), now: 100)
        #expect(s.observe(CodexRateLimits(), replaces: false, now: 200) == .none)
        #expect(s.blockedUntil == 5000)
        let lower = CodexRateLimits(primary: W(usedPercent: 3, windowMinutes: 300, resetsAt: 20000))
        #expect(s.observe(lower, replaces: false, now: 300) == .none)
        #expect(s.blockedUntil == 5000)
        #expect(s.limits?.primary?.usedPercent == 3)
        #expect(s.limits?.secondary?.usedPercent == 100)
    }

    @Test func sparseUpdateMergesIntoPrevious() {
        var s = CodexLimitState()
        _ = s.observe(CodexRateLimits(primary: W(usedPercent: 40, resetsAt: 2000), planType: "plus"), now: 100)
        #expect(s.observe(CodexRateLimits(secondary: W(usedPercent: 30, resetsAt: 9000)), replaces: false, now: 200) == .none)
        #expect(s.limits?.planType == "plus")
        #expect(s.limits?.primary?.usedPercent == 40)
        #expect(s.limits?.secondary?.usedPercent == 30)
    }

    /// 앱 시작 때 표에서 읽은 지난 값(막힘 흔적)은 막힘 근거가 아니다 — 새로 온 값으로만 막는다.
    @Test func staleStoredValueDoesNotBlock() {
        var s = CodexLimitState(limits: Self.full())
        #expect(s.observe(CodexRateLimits(), replaces: false, now: 200) == .none)
        #expect(s.blockedUntil == nil)
    }

    @Test func sparseFullWindowBlocks() {
        var s = CodexLimitState()
        let l = CodexRateLimits(primary: W(usedPercent: 100, windowMinutes: 300, resetsAt: 1795170748),
                                secondary: W(usedPercent: 31, windowMinutes: 10080, resetsAt: 1795257028),
                                reachedType: "rate_limit_reached")
        #expect(s.observe(l, replaces: false, now: 1795170592) == .blocked(until: 1795170748))
    }

    // MARK: - 표 저장

    // MARK: - 풀린 직후 다시 막힘

    @Test func hitSoonAfterReleaseIsQuietButStillBlocks() {
        var s = CodexLimitState()
        #expect(!s.isQuiet(now: 0))
        _ = s.usageLimitHit(now: 100)
        #expect(s.observe(CodexRateLimits(primary: W(usedPercent: 0, resetsAt: 20000)), now: 1000) == .released)
        #expect(s.releasedAt == 1000)
        #expect(s.isQuiet(now: 1000 + CodexLimitState.quietAfterRelease - 1))
        #expect(s.usageLimitHit(now: 1200) == .blocked(until: 1500))
        #expect(s.isBlocked)
        #expect(!s.isQuiet(now: 1000 + CodexLimitState.quietAfterRelease))
        #expect(CodexLimitState.quietAfterRelease == 600)
    }

    // MARK: - 표 저장

    @Test func windowsRoundTripThroughTable() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let l = CodexRateLimits(primary: W(usedPercent: 42, windowMinutes: 300, resetsAt: 1000),
                                secondary: W(usedPercent: 7, windowMinutes: 10080, resetsAt: 5000), planType: "plus")
        try q.write { db in for r in RateLimitWindow.rows(l, merged: l, seenAt: 9) { try r.save(db) } }
        // 창이 null 인 희소 값은 표의 창을 지우지 않는다.
        try q.write { db in for r in RateLimitWindow.rows(CodexRateLimits(), merged: l, seenAt: 10) { try r.save(db) } }
        let rows = try q.read { try RateLimitWindow.fetchAll($0) }
        #expect(rows.count == 2)
        #expect(CodexRateLimits(windows: rows) == l)
        #expect(CodexRateLimits(windows: []) == nil)
    }

    /// 합친 값을 저장할 때 이번에 온 창만 지금 시각으로 찍는다 — 이어받은 창은 표의 `seen_at` 그대로.
    @Test func onlyIncomingWindowsGetNewSeenAt() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let first = CodexRateLimits(primary: W(usedPercent: 42, resetsAt: 1000), secondary: W(usedPercent: 7, resetsAt: 5000),
                                    planType: "plus")
        try q.write { db in for r in RateLimitWindow.rows(first, merged: first, seenAt: 9) { try r.save(db) } }
        let sparse = CodexRateLimits(secondary: W(usedPercent: 8, resetsAt: 5001))
        let merged = sparse.merged(into: first)
        try q.write { db in for r in RateLimitWindow.rows(sparse, merged: merged, seenAt: 20) { try r.save(db) } }
        let rows = try q.read { try RateLimitWindow.fetchAll($0) }
        #expect(rows.first { $0.window == "primary" }?.seenAt == 9)
        let secondary = rows.first { $0.window == "secondary" }
        #expect(secondary?.seenAt == 20 && secondary?.usedPercent == 8 && secondary?.planType == "plus")
    }
}
