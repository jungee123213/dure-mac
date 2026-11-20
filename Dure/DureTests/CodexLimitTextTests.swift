import Testing
import Foundation
@testable import Dure

struct CodexLimitTextTests {
    let seoul = TimeZone(identifier: "Asia/Seoul")!

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
        #expect(CodexLimitText.line(l, blocked: false, timeZone: seoul)
                == "Codex 5시간 42% · 주간 17% (리셋 \(hm(1795060000)))")
    }

    @Test func blockedPrefersBlockedWindowReset() {
        let l = CodexRateLimits(primary: .init(usedPercent: 42, windowMinutes: 300, resetsAt: 1795060000),
                                secondary: .init(usedPercent: 100, windowMinutes: 10080, resetsAt: 1795500000))
        #expect(CodexLimitText.line(l, blocked: true, timeZone: seoul)
                == "한도 참 — Codex 5시간 42% · 주간 100% (리셋 \(hm(1795500000)))")
    }

    @Test func nilWhenNoValues() {
        #expect(CodexLimitText.line(nil, blocked: false, timeZone: seoul) == nil)
        #expect(CodexLimitText.line(CodexRateLimits(), blocked: false, timeZone: seoul) == nil)
    }

    @Test func windowLabelFromMinutes() {
        func line(_ m: Int?) -> String? {
            CodexLimitText.line(CodexRateLimits(primary: .init(usedPercent: 1, windowMinutes: m, resetsAt: nil)),
                                blocked: false, timeZone: seoul)
        }
        #expect(line(300) == "Codex 5시간 1%")
        #expect(line(10080) == "Codex 주간 1%")
        #expect(line(120) == "Codex 2시간 1%")
        #expect(line(45) == "Codex 45분 1%")
        #expect(line(nil) == "Codex 5시간 1%")
    }

    @Test func onlySecondaryAndNoReset() {
        let l = CodexRateLimits(secondary: .init(usedPercent: 9, windowMinutes: nil, resetsAt: nil))
        #expect(CodexLimitText.line(l, blocked: false, timeZone: seoul) == "Codex 주간 9%")
    }

    @Test func blockedWithoutWindowsStillShows() {
        #expect(CodexLimitText.line(nil, blocked: true, timeZone: seoul) == "한도 참 — Codex")
        #expect(CodexLimitText.line(CodexRateLimits(), blocked: true, timeZone: seoul) == "한도 참 — Codex")
    }
}
