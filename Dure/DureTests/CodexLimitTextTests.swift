import Testing
import Foundation
@testable import Dure

struct CodexLimitTextTests {
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    /// 아래 리셋 시각들보다 앞 — 낡은 창 거르기에 걸리지 않게.
    let now = 1795000000

    private func hm(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = seoul
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    @Test func formatsBothWindows() {
        let l = CodexRateLimits(primary: .init(usedPercent: 42, windowMinutes: 300, resetsAt: 1795060000),
                                secondary: .init(usedPercent: 17, windowMinutes: 10080, resetsAt: 1795500000))
        #expect(CodexLimitText.line(l, blocked: false, now: now, timeZone: seoul)
                == "Codex 5시간 42% · 주간 17% (리셋 \(hm(1795060000)))")
    }

    @Test func blockedPrefersBlockedWindowReset() {
        let l = CodexRateLimits(primary: .init(usedPercent: 42, windowMinutes: 300, resetsAt: 1795060000),
                                secondary: .init(usedPercent: 100, windowMinutes: 10080, resetsAt: 1795500000))
        #expect(CodexLimitText.line(l, blocked: true, now: now, timeZone: seoul)
                == "한도 참 — Codex 5시간 42% · 주간 100% (리셋 \(hm(1795500000)))")
    }

    @Test func nilWhenNoValues() {
        #expect(CodexLimitText.line(nil, blocked: false, now: now, timeZone: seoul) == nil)
        #expect(CodexLimitText.line(CodexRateLimits(), blocked: false, now: now, timeZone: seoul) == nil)
    }

    @Test func windowLabelFromMinutes() {
        func line(_ m: Int?) -> String? {
            CodexLimitText.line(CodexRateLimits(primary: .init(usedPercent: 1, windowMinutes: m, resetsAt: nil)),
                                blocked: false, now: now, timeZone: seoul)
        }
        #expect(line(300) == "Codex 5시간 1%")
        #expect(line(10080) == "Codex 주간 1%")
        #expect(line(120) == "Codex 2시간 1%")
        #expect(line(45) == "Codex 45분 1%")
        #expect(line(nil) == "Codex 5시간 1%")
    }

    @Test func onlySecondaryAndNoReset() {
        let l = CodexRateLimits(secondary: .init(usedPercent: 9, windowMinutes: nil, resetsAt: nil))
        #expect(CodexLimitText.line(l, blocked: false, now: now, timeZone: seoul) == "Codex 주간 9%")
    }

    @Test func blockedWithoutWindowsStillShows() {
        #expect(CodexLimitText.line(nil, blocked: true, now: now, timeZone: seoul) == "한도 참 — Codex")
        #expect(CodexLimitText.line(CodexRateLimits(), blocked: true, now: now, timeZone: seoul) == "한도 참 — Codex")
    }

    /// 리셋 시각이 지난 창은 낡은 값이다 — 그리지 않는다. 리셋 표시도 남은 창에서만.
    @Test func hidesWindowsPastTheirReset() {
        let l = CodexRateLimits(primary: .init(usedPercent: 100, windowMinutes: 300, resetsAt: 1795060000),
                                secondary: .init(usedPercent: 17, windowMinutes: 10080, resetsAt: 1795500000))
        #expect(CodexLimitText.line(l, blocked: false, now: 1795060001, timeZone: seoul)
                == "Codex 주간 17%")
        // 리셋 시각 그 순간까지는 보인다
        #expect(CodexLimitText.line(l, blocked: false, now: 1795060000, timeZone: seoul)
                == "Codex 5시간 100% · 주간 17% (리셋 \(hm(1795060000)))")
        // 리셋을 모르는 창은 거르지 않는다
        let unknown = CodexRateLimits(primary: .init(usedPercent: 3, windowMinutes: 300, resetsAt: nil))
        #expect(CodexLimitText.line(unknown, blocked: false, now: 1795999999, timeZone: seoul) == "Codex 5시간 3%")
    }

    /// 창이 모두 낡았으면 창이 없는 것과 같다.
    @Test func allWindowsStaleBehavesAsNoWindows() {
        let l = CodexRateLimits(primary: .init(usedPercent: 100, windowMinutes: 300, resetsAt: 1795060000),
                                secondary: .init(usedPercent: 17, windowMinutes: 10080, resetsAt: 1795500000))
        #expect(CodexLimitText.line(l, blocked: false, now: 1795600000, timeZone: seoul) == nil)
        #expect(CodexLimitText.line(l, blocked: true, now: 1795600000, timeZone: seoul) == "한도 참 — Codex")
    }
}
