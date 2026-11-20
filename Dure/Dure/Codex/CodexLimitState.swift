import Foundation

/// Codex 4단계 — 계정 한도 상태(D-46). **순수 값**이다. Codex 페인은 모두 같은 로그인이라 한 상태를 모든 Codex 페인 ·
/// Codex 조율자가 같이 쓴다(스토어가 하나 들고 있다). 판단만 여기서 하고 저장 · 타이머 · 알림 · 전달은 스토어와 `Dispatcher` 가 한다.
///
/// - 막힘: 새로 온 값에 `reachedType` 이 있거나 `ordinaryUsageAllowed == false` 거나 어느 창이 100% 이상. 또는 `usageLimitExceeded` 오류.
/// - 다시 볼 시각(`blockedUntil`): 꽉 찬 창의 `resetsAt` 중 가장 늦은 것. 모르거나 이미 지났으면 `now + recheckInterval`.
/// - 풀림: **막힌 동안에는 `read` 응답(통째 값)으로만** 판정한다. `updated` 알림은 희소해 null 창이 "모름" 이라(j-stage4 계획 영향 3-1)
///   합친 값으로 풀렸다고 짐작하지 않는다 — 스키마 주석도 퍼센트 · 시각으로 회복을 짐작하지 말라고 한다.
nonisolated struct CodexLimitState: Equatable {

    enum Change: Equatable {
        case none
        /// 막히지 않았다가 막혔다. 스토어는 알림 · 타이머를 건다.
        case blocked(until: Int)
        /// 이미 막혀 있는데 다시 볼 시각이 바뀌었다. 스토어는 타이머만 다시 건다(relay · 알림 없음).
        case rescheduled(until: Int)
        /// 막혀 있다가 풀렸다(`read` 값으로만).
        case released
    }

    /// 리셋 시각을 모를 때 · 다시 읽기에 실패했을 때 다시 볼 간격(초).
    static let recheckInterval = 300
    /// 리셋 시각 + 이만큼 뒤에 다시 읽는다 — 서버 쪽 리셋이 시각에 딱 맞지 않을 수 있다(`resetsAt` 은 읽을 때마다 ±1초 흔들린다).
    static let resetGrace = 30
    /// 풀린 뒤 이만큼 안에 다시 막히면 막기만 하고 사람 · 조율자에게 다시 알리지 않는다 — 풀림 → 이어 하기 → 곧바로 한도 실패가
    /// 되풀이될 때 알림 · relay 가 쌓이지 않게.
    static let quietAfterRelease = 600

    /// 마지막으로 안 값(합친 값). 대시보드 줄이 이걸 그린다.
    var limits: CodexRateLimits? = nil
    /// 막혀 있으면 다시 볼 시각. nil 이면 막히지 않음.
    var blockedUntil: Int? = nil
    /// 마지막으로 풀린 시각.
    var releasedAt: Int? = nil

    var isBlocked: Bool { blockedUntil != nil }

    /// 풀린 지 `quietAfterRelease` 가 안 됐나 — 이때 막히면 알리지 않는다.
    func isQuiet(now: Int) -> Bool {
        releasedAt.map { now - $0 < Self.quietAfterRelease } ?? false
    }

    /// 한도 값 하나. `replaces` — `read` 응답이면 true(통째로 바꿈), `updated` 알림이면 false(이전 값에 합침).
    /// 막힘 판정은 **새로 온 값**으로만 한다 — 합친 값에 남은 지난 흔적(앱 시작 때 표에서 읽은 값 등)으로 막지 않는다.
    mutating func observe(_ l: CodexRateLimits, replaces: Bool = true, now: Int) -> Change {
        limits = replaces ? l : l.merged(into: limits)
        if Self.blocks(l) {
            return block(until: Self.latestFullReset(in: limits, now: now) ?? now + Self.recheckInterval)
        }
        guard isBlocked, replaces else { return .none }
        blockedUntil = nil
        releasedAt = now
        return .released
    }

    /// 재시도 없는 `usageLimitExceeded`. 이미 막혀 있으면 아는 창으로 시각만 고칠 수 있다(모르면 그대로).
    mutating func usageLimitHit(now: Int) -> Change {
        let known = Self.latestFullReset(in: limits, now: now)
        if isBlocked {
            guard let known else { return .none }
            return block(until: known)
        }
        return block(until: known ?? now + Self.recheckInterval)
    }

    /// 다시 볼 시각에 읽을 수 있는 Codex 페인이 없었다(또는 응답을 기다리는 중) — 간격 뒤에 다시 본다.
    mutating func recheckFailed(now: Int) {
        blockedUntil = now + Self.recheckInterval
    }

    private mutating func block(until: Int) -> Change {
        let was = blockedUntil
        blockedUntil = until
        if was == nil { return .blocked(until: until) }
        return was == until ? .none : .rescheduled(until: until)
    }

    static func blocks(_ l: CodexRateLimits) -> Bool {
        l.reachedType != nil || l.ordinaryUsageAllowed == false
            || [l.primary, l.secondary].contains { ($0?.usedPercent ?? 0) >= 100 }
    }

    /// 꽉 찬 창의 리셋 시각 중 가장 늦은 것. 없거나 이미 지났으면 nil — 지난 시각으로 걸면 곧바로 다시 읽기를 되풀이한다.
    static func latestFullReset(in l: CodexRateLimits?, now: Int) -> Int? {
        guard let l else { return nil }
        let resets = [l.primary, l.secondary].compactMap { w in w.flatMap { $0.usedPercent >= 100 ? $0.resetsAt : nil } }
        guard let latest = resets.max(), latest > now else { return nil }
        return latest
    }
}

// MARK: - v10 `rate_limit` 표

extension RateLimitWindow {
    static let codexKind = "codex"

    /// 표에 쓸 행. **이번에 온 값(`incoming`)에 있는 창만** — null 창(희소 알림)은 표의 지난 창(과 그 `seen_at`)을 그대로 둔다.
    /// 계획 · 도달 칸은 합친 값(`merged`)에서 — 알림의 `planType` 은 늘 null 이다(j-stage4 1절).
    nonisolated static func rows(_ incoming: CodexRateLimits, merged: CodexRateLimits, seenAt: Int) -> [RateLimitWindow] {
        [("primary", incoming.primary), ("secondary", incoming.secondary)].compactMap { name, w in
            w.map { RateLimitWindow(kind: codexKind, window: name, usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes,
                                    resetsAt: $0.resetsAt, planType: merged.planType, reachedType: merged.reachedType,
                                    seenAt: seenAt) }
        }
    }
}

extension CodexRateLimits {
    /// 앱 시작 때 표에서 읽은 마지막 값. Codex 행이 없으면 nil. `ordinaryUsageAllowed` 는 저장하지 않는다(`read` 에만 있다).
    nonisolated init?(windows: [RateLimitWindow]) {
        let codex = windows.filter { $0.kind == RateLimitWindow.codexKind }
        guard !codex.isEmpty else { return nil }
        func window(_ name: String) -> Window? {
            codex.first { $0.window == name }.map { Window(usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt) }
        }
        let newest = codex.max { $0.seenAt < $1.seenAt }
        self.init(primary: window("primary"), secondary: window("secondary"),
                  planType: newest?.planType, reachedType: newest?.reachedType)
    }
}
