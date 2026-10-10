// Dure/DureTests/MergeWatcherTests.swift
import Foundation
import Testing
@testable import Dure

struct MergeWatcherTests {

    func ok(_ s: String) -> CommandResult { CommandResult(status: 0, stdout: Data(s.utf8), stderr: Data(), timedOut: false) }

    static let two = """
    [oh-my-zsh] hi
    __DURE_OUT__
    [
      {"number": 120, "url": "https://github.com/o/r/pull/120", "mergedAt": "2026-09-01T00:00:00Z",
       "createdAt": "2026-08-30T00:00:00Z", "headRefOid": "aaa"},
      {"number": 289, "url": "https://github.com/o/r/pull/289", "mergedAt": "2026-10-09T20:17:08Z",
       "createdAt": "2026-10-09T10:00:00Z", "headRefOid": "bbb"}
    ]
    """

    @Test func 머지된_PR_목록을_읽는다() {
        let ms = MergeWatcher.parse(ok(Self.two))
        #expect(ms.map(\.number) == [120, 289])
        #expect(ms[1].head == "bbb" && ms[1].mergedAt == ObsParser.epoch("2026-10-09T20:17:08Z"))
    }

    /// 리뷰 P1-D · 시나리오 6 — 같은 브랜치 이름을 다시 쓴 경우 옛 PR 을 잡지 않는다.
    @Test func 작업_시작_뒤_머지된_것_중_가장_이른_것() {
        let ms = MergeWatcher.parse(ok(Self.two))
        let workStarted = ObsParser.epoch("2026-10-09T09:00:00Z")!
        #expect(MergeWatcher.choose(ms, firstTs: workStarted)?.number == 289)
        #expect(MergeWatcher.choose(ms, firstTs: ObsParser.epoch("2026-10-10T00:00:00Z")!) == nil)
    }

    @Test func 실패나_표지_없음은_빈_목록() {
        #expect(MergeWatcher.parse(ok("__DURE_OUT__\n[]\n")).isEmpty)
        #expect(MergeWatcher.parse(CommandResult(status: 1, stdout: Data(), stderr: Data(), timedOut: false)).isEmpty)
        #expect(MergeWatcher.parse(ok("[{\"number\":1}]")).isEmpty)
    }

    @Test func 명령은_읽기만() {
        #expect(MergeWatcher.script(githubRepo: "Moa-Map/moamap-iOS", branch: "feat/#52/splash") ==
                "echo __DURE_OUT__; gh pr list -R 'Moa-Map/moamap-iOS' --head 'feat/#52/splash' --state merged --json number,url,mergedAt,createdAt,headRefOid --limit 10")
    }

    static func unit(pr: Int? = nil) -> WorkUnit {
        WorkUnit(unitKey: "k", baseKey: "k", kind: .issueBranch, repoRoot: "/r/ios", branch: "feat/#52/x",
                 githubRepo: "Moa-Map/moamap-iOS", prNumber: pr, firstTs: 0, lastTs: 0)
    }

    @Test func diff_통계() {
        #expect(MergeWatcher.diffStatScript(Self.unit(pr: 53)) ==
                "echo __DURE_OUT__; gh pr view 53 -R 'Moa-Map/moamap-iOS' --json additions,deletions,changedFiles")
        #expect(MergeWatcher.parseDiffStat(ok("__DURE_OUT__\n{\"additions\":120,\"changedFiles\":4,\"deletions\":8}\n")) ==
                "4 files changed, 120 insertions(+), 8 deletions(-)")
        let local = MergeWatcher.diffStatScript(Self.unit()) ?? ""
        #expect(local.hasPrefix("echo __DURE_OUT__; git -C '/r/ios' diff --shortstat") && local.hasSuffix("...'feat/#52/x'"))
        #expect(MergeWatcher.parseDiffStat(ok("__DURE_OUT__\n 3 files changed, 10 insertions(+)\n")) == "3 files changed, 10 insertions(+)")
        var day = Self.unit(); day.kind = .defaultBranch
        #expect(MergeWatcher.diffStatScript(day) == nil)
    }

    @Test(arguments: [("4 files changed, 120 insertions(+), 8 deletions(-)", 128), ("3 files changed, 10 insertions(+)", 10),
                      ("1 file changed, 2 deletions(-)", 2), ("무엇도 아님", nil)] as [(String, Int?)])
    func 변경_줄(_ s: String, _ n: Int?) {
        #expect(MergeWatcher.lines(fromStat: s) == n)
    }
}
