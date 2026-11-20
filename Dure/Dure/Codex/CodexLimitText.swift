import Foundation

/// 대시보드 지도 머리의 Codex 한도 한 줄. 순수 함수 — `blocked` 는 호출 쪽이 `CodexLimitState.isBlocked` 로 준다
/// (저장된 `reachedType` 은 앱 기동 뒤 첫 읽기 전까지 낡았을 수 있어 여기서 판정하지 않는다).
/// 리셋 시각이 이미 지난 창은 그리지 않는다 — 그 값은 리셋 전의 것이라 낡았다(다음 읽기까지 모른다).
nonisolated enum CodexLimitText {
    static func line(_ stored: CodexRateLimits?, blocked: Bool, now: Int = Int(Date().timeIntervalSince1970),
                     timeZone: TimeZone = .current) -> String? {
        guard let stored else { return blocked ? "한도 참 — Codex" : nil }
        func fresh(_ w: CodexRateLimits.Window?) -> CodexRateLimits.Window? {
            guard let w else { return nil }
            if let reset = w.resetsAt, reset < now { return nil }
            return w
        }
        var l = stored
        l.primary = fresh(stored.primary)
        l.secondary = fresh(stored.secondary)
        var parts: [String] = []
        if let p = l.primary { parts.append("\(label(p.windowMinutes, fallback: "5시간")) \(p.usedPercent)%") }
        if let s = l.secondary { parts.append("\(label(s.windowMinutes, fallback: "주간")) \(s.usedPercent)%") }
        guard !parts.isEmpty else { return blocked ? "한도 참 — Codex" : nil }

        var text = "Codex " + parts.joined(separator: " · ")
        if let reset = resetEpoch(l) { text += " (리셋 \(time(reset, timeZone)))" }
        return blocked ? "한도 참 — " + text : text
    }

    /// 막힌 창(100% 이상)의 리셋, 둘 다면 늦은 쪽. 없으면 primary 의 리셋.
    private static func resetEpoch(_ l: CodexRateLimits) -> Int? {
        let full = [l.primary, l.secondary].compactMap { $0 }.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt)
        return full.max() ?? l.primary?.resetsAt
    }

    private static func label(_ minutes: Int?, fallback: String) -> String {
        guard let m = minutes else { return fallback }
        if m == 300 { return "5시간" }
        if m == 10080 { return "주간" }
        if m > 0, m % 60 == 0 { return "\(m / 60)시간" }
        return "\(m)분"
    }

    private static func time(_ epoch: Int, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
