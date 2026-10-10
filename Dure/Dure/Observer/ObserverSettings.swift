import Foundation

nonisolated struct ObserverSettings: Equatable, Sendable {
    var enabled = true
    var autoEvaluate = true
    /// 사람 턴 + 배분 받은 턴. 사람 프롬프트만 세면 개입을 줄인 성공 사례가 빠진다(리뷰 P1-C).
    var minTurns = 2
    /// 오늘 시작한 자동 실행(실패 포함). 사람이 누른 것은 세지 않는다.
    var dailyCap = 10
    var autoEvaluateDayUnits = false
    var excludes = ["/private/tmp/", "/tmp/"]

    private static let p = "observer."

    static func load(from d: UserDefaults) -> ObserverSettings {
        var s = ObserverSettings()
        if d.object(forKey: p + "enabled") != nil { s.enabled = d.bool(forKey: p + "enabled") }
        if d.object(forKey: p + "autoEvaluate") != nil { s.autoEvaluate = d.bool(forKey: p + "autoEvaluate") }
        if d.object(forKey: p + "minTurns") != nil { s.minTurns = d.integer(forKey: p + "minTurns") }
        if d.object(forKey: p + "dailyCap") != nil { s.dailyCap = d.integer(forKey: p + "dailyCap") }
        if d.object(forKey: p + "autoEvaluateDayUnits") != nil { s.autoEvaluateDayUnits = d.bool(forKey: p + "autoEvaluateDayUnits") }
        if let e = d.stringArray(forKey: p + "excludes") { s.excludes = e }
        return s
    }

    func save(to d: UserDefaults) {
        let p = Self.p
        d.set(enabled, forKey: p + "enabled")
        d.set(autoEvaluate, forKey: p + "autoEvaluate")
        d.set(minTurns, forKey: p + "minTurns")
        d.set(dailyCap, forKey: p + "dailyCap")
        d.set(autoEvaluateDayUnits, forKey: p + "autoEvaluateDayUnits")
        d.set(excludes, forKey: p + "excludes")
    }

    /// 감시자가 처음 켜진 시각. 설정이 아니라 기록이라 `save` 에 넣지 않는다 — 설정을 고쳐도 바뀌면 안 된다.
    static let firstStartKey = p + "firstStart"

    /// 없으면 지금을 적고 돌려준다. 첫 수집이 지난 30일의 이슈 브랜치를 한꺼번에 만들므로,
    /// 그 머지들까지 자동 평가하면 첫 실행에 상한을 다 쓰고 옛 작업만 평가하게 된다(최종 리뷰 F1).
    static func firstStart(in d: UserDefaults, now: Int) -> Int {
        if d.object(forKey: firstStartKey) != nil { return d.integer(forKey: firstStartKey) }
        d.set(now, forKey: firstStartKey)
        return now
    }
}

/// 평가 큐의 판단. 스펙 v2 3-2 · 3-3. 순수 함수.
nonisolated enum ObserverRules {

    /// 이보다 오래 손대지 않은 작업은 머지를 더 보지 않는다 — 버려진 브랜치마다 10분에 한 번씩 `gh` 를 부르지 않게.
    static let mergeWatchWindow = 30 * 86_400

    /// 평가 여부와 무관 — 수동 중간 평가 뒤에도 머지를 놓치지 않는다(리뷰 P1-B).
    static func watchesMerge(_ u: WorkUnit, now: Int) -> Bool {
        u.kind == .issueBranch && u.githubRepo != nil && u.mergedAt == nil && now - u.lastTs <= mergeWatchWindow
    }

    /// 머지 기록은 언제나 남기되, 자동 평가는 감시자가 켜진 **뒤에** 머지된 것만.
    /// 켜기 전의 머지는 사람이 [평가] 를 누르면 된다 — 백필이 하루 상한을 먹지 않게(최종 리뷰 F1).
    static func shouldAutoEnqueue(_ u: WorkUnit, firstStart: Int, _ s: ObserverSettings) -> Bool {
        guard s.autoEvaluate, let merged = u.mergedAt, merged >= firstStart else { return false }
        return eligible(u, s)
    }

    /// 머지를 발견한 순간이 아니라 **수집이 끝날 때마다** 다시 보는 규칙. 머지 발견 때는 자격이 없다가
    /// 이후 수집으로 자격이 생긴 단위를 놓치지 않는다(`watchesMerge` 는 merged 단위를 빼서 다시 안 본다).
    /// 조건은 `shouldAutoEnqueue` 를 그대로 쓰고, 자동 실행 이력(상태 무관)이 없을 때만 더한다 — 같은 규칙을 두 군데서 쓴다.
    static func needsAutoEvaluation(_ u: WorkUnit, hasAutoRun: Bool, firstStart: Int, _ s: ObserverSettings) -> Bool {
        !hasAutoRun && shouldAutoEnqueue(u, firstStart: firstStart, s)
    }

    /// 자동 대기 실행이 지금은 못 도는 상태(자동 평가 꺼짐 또는 하루 상한). `next` 와 UI 가 같은 판단을 쓴다.
    static func autoQueuePaused(autoRunsToday: Int, _ s: ObserverSettings) -> Bool {
        !s.autoEvaluate || autoRunsToday >= s.dailyCap
    }

    static func eligible(_ u: WorkUnit, _ s: ObserverSettings) -> Bool {
        u.activity >= s.minTurns || u.editCount > 0
    }

    static func dayUnitDue(_ u: WorkUnit, today: String, _ s: ObserverSettings, hasRun: Bool) -> Bool {
        guard s.enabled, s.autoEvaluate, s.autoEvaluateDayUnits, !hasRun,
              u.kind == .defaultBranch || u.kind == .noGit, let day = u.day else { return false }
        return day < today && eligible(u, s)
    }

    /// 사람이 누른 것 먼저(오래된 순), 자동은 켜져 있고 상한 안일 때만.
    static func next(queued: [EvaluationRun], autoRunsToday: Int, _ s: ObserverSettings) -> EvaluationRun? {
        let byAge: (EvaluationRun, EvaluationRun) -> Bool = { $0.createdAt < $1.createdAt }
        if let m = queued.filter({ $0.trigger == .manual }).sorted(by: byAge).first { return m }
        guard !autoQueuePaused(autoRunsToday: autoRunsToday, s) else { return nil }
        return queued.filter { $0.trigger == .auto }.sorted(by: byAge).first
    }

    static func isStale(unit: WorkUnit, run: EvaluationRun) -> Bool {
        (run.sourceRevision ?? 0) < unit.sourceRevision
    }

    /// 기준 문서 머리의 `**재검토 기한:** YYYY-MM-DD`.
    static func referenceDeadline(from text: String) -> String? {
        guard let r = text.range(of: #"재검토 기한:\*\* \d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(text[r].suffix(10))
    }
}
