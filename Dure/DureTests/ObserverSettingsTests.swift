import Foundation
import Testing
@testable import Dure

struct ObserverSettingsTests {

    @Test func 저장하고_다시_읽는다() throws {
        let d = try #require(UserDefaults(suiteName: "obs-\(UUID().uuidString)"))
        #expect(ObserverSettings.load(from: d) == ObserverSettings())
        var s = ObserverSettings()
        s.autoEvaluate = false; s.minTurns = 5; s.dailyCap = 2; s.autoEvaluateDayUnits = true; s.excludes = ["/x/"]
        s.save(to: d)
        #expect(ObserverSettings.load(from: d) == s)
    }

    static func unit(_ kind: UnitKind = .issueBranch, human: Int = 0, peer: Int = 0, edits: Int = 0, merged: Bool = false,
                     github: String? = "o/r", day: String? = nil) -> WorkUnit {
        WorkUnit(unitKey: UUID().uuidString, baseKey: "b", kind: kind, branch: "feat/#1/x", day: day, githubRepo: github,
                 mergedAt: merged ? 1 : nil, firstTs: 0, lastTs: 0, humanTurns: human, peerTurns: peer, editCount: edits)
    }

    /// 수동 평가를 했어도 머지는 계속 본다 — 평가 상태는 단위에 없다(시나리오 2).
    @Test func 머지_감시_대상() {
        #expect(ObserverRules.watchesMerge(Self.unit(), now: 0))
        #expect(!ObserverRules.watchesMerge(Self.unit(merged: true), now: 0))
        #expect(!ObserverRules.watchesMerge(Self.unit(github: nil), now: 0))
        #expect(!ObserverRules.watchesMerge(Self.unit(.defaultBranch), now: 0))
    }

    @Test func 자동_평가가_필요한_단위() {
        let s = ObserverSettings()
        var u = Self.unit(human: 3)
        u.mergedAt = 2000
        #expect(ObserverRules.needsAutoEvaluation(u, hasAutoRun: false, firstStart: 1000, s))
        #expect(!ObserverRules.needsAutoEvaluation(u, hasAutoRun: true, firstStart: 1000, s))
        #expect(!ObserverRules.needsAutoEvaluation(u, hasAutoRun: false, firstStart: 3000, s))
    }

    @Test func 자동_대기_보류_판단() {
        var s = ObserverSettings()
        s.dailyCap = 2
        #expect(!ObserverRules.autoQueuePaused(autoRunsToday: 0, s))
        #expect(ObserverRules.autoQueuePaused(autoRunsToday: 2, s))
        s.autoEvaluate = false
        #expect(ObserverRules.autoQueuePaused(autoRunsToday: 0, s))
    }

    /// F5d — 30일 넘게 손대지 않은 브랜치는 더 보지 않는다(버려진 브랜치마다 gh 를 부르지 않게).
    @Test func 오래된_작업은_머지를_보지_않는다() {
        let day = 86_400
        #expect(ObserverRules.watchesMerge(Self.unit(), now: 30 * day))
        #expect(!ObserverRules.watchesMerge(Self.unit(), now: 30 * day + 1))
    }

    /// 최종 리뷰 F1 — 머지가 감시자 첫 시작 뒤일 때만 자동 평가.
    @Test func 첫_시작_전_머지는_자동_평가하지_않는다() {
        var s = ObserverSettings()
        var u = Self.unit(human: 3)
        u.mergedAt = 1000
        #expect(ObserverRules.shouldAutoEnqueue(u, firstStart: 1000, s))
        #expect(ObserverRules.shouldAutoEnqueue(u, firstStart: 999, s))
        #expect(!ObserverRules.shouldAutoEnqueue(u, firstStart: 1001, s))
        #expect(!ObserverRules.shouldAutoEnqueue(Self.unit(human: 3), firstStart: 0, s))     // 머지 전
        #expect(!ObserverRules.shouldAutoEnqueue(Self.unit(human: 1, merged: true), firstStart: 0, s))   // 자격 없음
        s.autoEvaluate = false
        #expect(!ObserverRules.shouldAutoEnqueue(u, firstStart: 0, s))
    }

    @Test func 첫_시작_시각은_한_번만_적는다() throws {
        let d = try #require(UserDefaults(suiteName: "obs-\(UUID().uuidString)"))
        #expect(ObserverSettings.firstStart(in: d, now: 50) == 50)
        #expect(ObserverSettings.firstStart(in: d, now: 99) == 50)
        var s = ObserverSettings(); s.dailyCap = 3; s.save(to: d)
        #expect(ObserverSettings.firstStart(in: d, now: 99) == 50)
    }

    /// Review Focus 2 · 시나리오 1 — 사람 프롬프트 0개여도 배분 받은 턴 · 파일 수정이 있으면 자격.
    @Test func 배분만으로_끝난_작업도_자격이_있다() {
        let s = ObserverSettings()
        #expect(ObserverRules.eligible(Self.unit(peer: 2), s))
        #expect(ObserverRules.eligible(Self.unit(peer: 1, edits: 3), s))
        #expect(ObserverRules.eligible(Self.unit(human: 1, peer: 1), s))
        #expect(!ObserverRules.eligible(Self.unit(human: 1), s))           // "깃 상태 봐줘" 한 번
    }

    @Test func 날짜_단위는_설정을_켜야_하루가_지나면() {
        var s = ObserverSettings()
        let u = Self.unit(.defaultBranch, human: 3, day: "2026-10-09")
        #expect(!ObserverRules.dayUnitDue(u, today: "2026-10-10", firstStartDay: "2026-10-01", s, hasRun: false))
        s.autoEvaluateDayUnits = true
        #expect(ObserverRules.dayUnitDue(u, today: "2026-10-10", firstStartDay: "2026-10-01", s, hasRun: false))
        #expect(!ObserverRules.dayUnitDue(u, today: "2026-10-10", firstStartDay: "2026-10-01", s, hasRun: true))
        // 첫 시작 날짜 이전의 날은 자동 평가하지 않는다
        #expect(!ObserverRules.dayUnitDue(u, today: "2026-10-10", firstStartDay: "2026-10-10", s, hasRun: false))
        #expect(ObserverRules.dayUnitDue(u, today: "2026-10-10", firstStartDay: "2026-10-09", s, hasRun: false))
        #expect(!ObserverRules.dayUnitDue(Self.unit(.defaultBranch, human: 3, day: "2026-10-10"), today: "2026-10-10", firstStartDay: "2026-10-01", s, hasRun: false))
    }

    static func run(_ t: RunTrigger, created: Int) -> EvaluationRun {
        EvaluationRun(id: "\(t)-\(created)", unitId: "u", trigger: t, status: .queued, createdAt: created)
    }

    /// 시나리오 11 — 자동 평가를 끄면 대기 중인 자동 실행도 꺼내지 않는다. 상한은 자동만.
    @Test func 큐에서_꺼내는_순서와_상한() {
        var s = ObserverSettings()
        let auto1 = Self.run(.auto, created: 1), manual = Self.run(.manual, created: 9)
        #expect(ObserverRules.next(queued: [auto1, manual], autoRunsToday: 0, s) == manual)
        #expect(ObserverRules.next(queued: [auto1], autoRunsToday: 10, s) == nil)
        #expect(ObserverRules.next(queued: [manual], autoRunsToday: 10, s) == manual)
        s.autoEvaluate = false
        #expect(ObserverRules.next(queued: [auto1], autoRunsToday: 0, s) == nil)
    }

    @Test func 평가_뒤_변경() {
        var u = Self.unit()
        u.sourceRevision = 7
        var r = Self.run(.manual, created: 1)
        r.sourceRevision = 7
        #expect(!ObserverRules.isStale(unit: u, run: r))
        u.sourceRevision = 8
        #expect(ObserverRules.isStale(unit: u, run: r))
    }

    @Test func 기준_문서_재검토_기한() {
        #expect(ObserverRules.referenceDeadline(from: "- **확인일:** 2026-10-10 · **재검토 기한:** 2027-01-10\n") == "2027-01-10")
        #expect(ObserverRules.referenceDeadline(from: "없음") == nil)
    }

    @Test func 경로와_수집_제외() {
        let dirs = ObserverDirs(root: URL(fileURLWithPath: "/h/.dure/observer"), claudeHome: URL(fileURLWithPath: "/h/.claude"),
                                workspacesRoot: URL(fileURLWithPath: "/h/.dure/workspaces"), settingsDir: URL(fileURLWithPath: "/h/.dure/settings"))
        var s = ObserverSettings()
        s.excludes = []
        #expect(dirs.collectExcludes(s) == ["/h/.dure/observer/"])
        #expect(dirs.runDir(unit: "u1", run: "r1").path == "/h/.dure/observer/units/u1/runs/r1")
        #expect(dirs.projects.path == "/h/.claude/projects")
        #expect(dirs.chatSettings.path == "/h/.dure/settings/observer.json")
    }
}
