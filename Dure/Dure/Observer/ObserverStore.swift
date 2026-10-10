// Dure/Dure/Observer/ObserverStore.swift
import AppKit
import Foundation
import GRDB
import Observation

/// 감시자의 흐름과 화면 상태. `DureStore` 와 나눈 이유는 그쪽이 이미 크고, 감시자는 워크스페이스에 속하지 않기 때문이다.
/// `DureStore` 와 주고받는 것은 둘 — "Stop 이 왔다"(수집 계기) · "승인 프롬프트가 떴다".
@MainActor
@Observable
final class ObserverStore {
    private(set) var units: [WorkUnit] = []
    private(set) var latestRun: [String: EvaluationRun] = [:]
    private(set) var backlog: [BacklogItem] = []
    private(set) var runningRunID: String?
    private(set) var ghProblem: String?
    private(set) var formatWarning = false
    private(set) var unknownTypes = 0
    private(set) var autoRunsToday = 0
    /// 묻기 페인 — 한 번에 하나. 뷰가 아니라 여기 두는 이유: 탭을 바꾸면 뷰 상태는 사라지지만 대화는 이어져야 한다(최종 리뷰 F4).
    private(set) var chat: ChatPane?
    var settings: ObserverSettings { didSet { settings.save(to: defaults) } }
    let dirs: ObserverDirs

    var referenceMissing: Bool {
        !FileManager.default.fileExists(atPath: dirs.reference.appendingPathComponent("practices.md").path)
    }
    var referenceExpired: Bool {
        guard let text = try? String(contentsOf: dirs.reference.appendingPathComponent("practices.md"), encoding: .utf8),
              let deadline = ObserverRules.referenceDeadline(from: text) else { return false }
        return deadline < WorkUnitRules.day(now(), timeZone: .current)
    }

    @ObservationIgnored private let db: DatabaseQueue
    @ObservationIgnored private let runner: CommandRunning
    @ObservationIgnored private let resolver: RepoResolving
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var collectAgain = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored var now: () -> Int = { Int(Date().timeIntervalSince1970) }

    /// 기본값을 인자에 두면 호출 쪽 격리 문맥에서 평가돼 경고가 난다 — 실물 조합은 아래 편의 init 이 넘긴다.
    init(db: DatabaseQueue, runner: CommandRunning, resolver: RepoResolving, defaults: UserDefaults, dirs: ObserverDirs) {
        self.db = db
        self.runner = runner
        self.resolver = resolver
        self.defaults = defaults
        self.dirs = dirs
        self.settings = ObserverSettings.load(from: defaults)
    }

    convenience init() {
        self.init(db: AppDatabase.queue, runner: LiveCommandRunner(), resolver: LiveRepoResolver(),
                  defaults: .standard, dirs: ObserverPaths.live)
    }

    /// 앱 시작 때 한 번. **테스트 호스트에서는 아무것도 하지 않는다.**
    func start() {
        guard !DureStore.isTestHost, loops.isEmpty else { return }
        _ = ObserverSettings.firstStart(in: defaults, now: now())
        // 평가 중에 앱을 끄면 `claude -p` 가 고아로 남아 한도를 계속 쓴다 — 트리째 죽인다(최종 리뷰 F5e).
        let runner = runner
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            runner.cancelAll()
        }
        do { try SessionSettings.writeObserver(root: dirs.settingsDir.deletingLastPathComponent()) }
        catch { NSLog("[Dure] 감시자 설정 쓰기 실패: \(error)") }
        let t = now()
        do { _ = try db.write { try EvaluationJob.recover(now: t, in: $0) } }
        catch { NSLog("[Dure] 감시자 평가 복구 실패: \(error)") }
        reload()
        collectSoon()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.collectSoon()
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkMerges()
                try? await Task.sleep(for: .seconds(MergeWatcher.interval))
            }
        })
    }

    private var collectConfig: CollectConfig {
        CollectConfig(projectsDir: dirs.projects, excludes: dirs.collectExcludes(settings), workspacesRoot: dirs.workspacesRoot.path)
    }

    // MARK: - 수집

    func collectSoon() {
        guard settings.enabled else { return }
        if collecting { collectAgain = true; return }
        collecting = true
        let db = db, resolver = resolver, config = collectConfig
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try ObsCollector.collect(db: db, config: config, resolver: resolver) }
            }.value
            guard let self else { return }
            if case .failure(let e) = result { NSLog("[Dure] 감시자 수집 실패: \(e)") }
            self.collecting = false
            self.queueDueDayUnits()
            await self.queueLateEligible()
            self.reload()
            self.pump()
            if self.collectAgain { self.collectAgain = false; self.collectSoon() }
        }
    }

    func recordPermissionPrompt(ccSessionID: String) {
        let ts = now()
        do { try db.write { try ObsPermission(ccSessionId: ccSessionID, ts: ts).insert($0) } }
        catch { NSLog("[Dure] 승인 프롬프트 기록 실패: \(error)") }
    }

    // MARK: - 큐

    func requestEvaluation(_ unitID: String) {
        let t = now()
        do { _ = try db.write { try EvaluationJob.enqueue(unitID: unitID, trigger: .manual, now: t, in: $0) } }
        catch { NSLog("[Dure] 평가 요청 실패: \(error)") }
        reload()
        pump()
    }

    func checkMerges() async {
        guard settings.enabled else { return }
        let watched = units.isEmpty ? ((try? await db.read { try WorkUnit.fetchAll($0) }) ?? []) : units
        let t = now()
        let targets = watched.filter { ObserverRules.watchesMerge($0, now: t) }
        guard !targets.isEmpty else { return }
        let runner = runner
        let auth = await runner.run(MergeWatcher.authScript, timeout: 30)
        guard auth.status == 0, !auth.timedOut else {
            ghProblem = "gh 가 없거나 로그인되어 있지 않아 PR 머지를 자동으로 감지하지 못합니다. 수동 [평가] 는 됩니다."
            return
        }
        ghProblem = nil
        // start() 가 이미 적었다. 여기서도 부르는 것은 start 를 거치지 않는 경로(테스트)에서도 같은 규칙을 쓰기 위해서다.
        let s = settings, firstStart = ObserverSettings.firstStart(in: defaults, now: t)
        for u in targets {
            guard let repo = u.githubRepo, let branch = u.branch else { continue }
            let merges = MergeWatcher.parse(await runner.run(MergeWatcher.script(githubRepo: repo, branch: branch), timeout: 60))
            guard let m = MergeWatcher.choose(merges, firstTs: u.firstTs) else { continue }
            try? await db.write { db in
                guard var x = try WorkUnit.fetchOne(db, key: u.id) else { return }
                x.prNumber = m.number
                x.prUrl = m.url
                x.prHead = m.head
                x.mergedAt = m.mergedAt
                try x.update(db)
                // 같은 쓰기 안에서 머지 뒤 턴을 다음 세대로 옮긴다 — 다음 수집까지 섞인 상태를 평가가 집지 않게.
                // 수집 잠금은 잡지 않는다: 한 트랜잭션이라 수집 청크와 섞이지 않고, 수집도 끝에서 같은 정합을 돈다.
                try GenerationSplit.reconcile(in: db)
                // 자동 평가 자격은 옮긴 뒤의(머지 전 작업만의) 숫자로 본다.
                x = try WorkUnit.fetchOne(db, key: u.id) ?? x
                if ObserverRules.shouldAutoEnqueue(x, firstStart: firstStart, s) {
                    _ = try EvaluationJob.enqueue(unitID: x.id, trigger: .auto, now: t, in: db)
                }
            }
        }
        reload()
        pump()
    }

    /// 수집이 끝날 때마다 — 머지를 발견한 뒤에야 자격이 생긴 단위를 자동 평가에 넣는다.
    /// `await` 라 DB 쓰기는 메인을 막지 않는다.
    func queueLateEligible() async {
        guard settings.enabled, settings.autoEvaluate else { return }
        let s = settings, t = now(), firstStart = ObserverSettings.firstStart(in: defaults, now: t)
        do { _ = try await db.write { try EvaluationJob.enqueueLateEligible(firstStart: firstStart, s, now: t, in: $0) } }
        catch { NSLog("[Dure] 감시자 자격 재확인 실패: \(error)") }
    }

    private func queueDueDayUnits() {
        let s = settings, t = now(), today = WorkUnitRules.day(t, timeZone: .current)
        guard s.autoEvaluateDayUnits else { return }
        try? db.write { db in
            for u in try WorkUnit.filter([UnitKind.defaultBranch.rawValue, UnitKind.noGit.rawValue].contains(Column("kind"))).fetchAll(db) {
                let hasRun = try EvaluationRun.filter(Column("unit_id") == u.id).fetchCount(db) > 0
                if ObserverRules.dayUnitDue(u, today: today, s, hasRun: hasRun) {
                    _ = try EvaluationJob.enqueue(unitID: u.id, trigger: .auto, now: t, in: db)
                }
            }
        }
    }

    /// 한 번에 하나. 끝나면 다음을 민다.
    func pump() {
        guard runningRunID == nil, settings.enabled else { return }
        let startOfDay = Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now()))).timeIntervalSince1970)
        guard let read = try? db.read({ db in
            (try EvaluationRun.filter(Column("status") == RunStatus.queued.rawValue).fetchAll(db),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM evaluation_run WHERE trigger = 'auto' AND started_at >= ?",
                              arguments: [startOfDay]) ?? 0)
        }) else { return }
        autoRunsToday = read.1
        guard let next = ObserverRules.next(queued: read.0, autoRunsToday: read.1, settings) else { return }
        runningRunID = next.id
        let db = db, resolver = resolver, config = collectConfig
        let env = EvalEnvironment(db: db, runner: runner, dirs: dirs,
                                  flush: { _ = try? ObsCollector.collect(db: db, config: config, resolver: resolver) })
        let id = next.id, title = units.first { $0.id == next.unitId }?.title ?? "작업"
        reload()
        Task { [weak self] in
            // nonisolated async 가 호출자 액터에서 돌 수 있는 설정에서도 메인을 막지 않게 분리한다.
            let outcome = await Task.detached(priority: .utility) { await EvaluationJob.run(runID: id, env: env) }.value
            guard let self else { return }
            self.runningRunID = nil
            self.reload()
            // 실행을 집지도 못하고 실패했으면(집는 쓰기 실패) 그대로 queued 다 — 바로 pump 하면 같은 실행을 다시 집어
            // 같은 실패와 알림을 쉬지 않고 반복한다. 다음 수집 틱(30초)이 다시 민다(최종 리뷰 F5c).
            if case .failed(let m) = outcome,
               (try? await self.db.read { try EvaluationRun.fetchOne($0, key: id) })?.status == .queued {
                NSLog("[Dure] 감시자 평가를 시작하지 못함(다음 틱에 다시): \(m)")
                return
            }
            switch outcome {
            case let .evaluated(o, rejected):
                Notifier.post(title: "\(title) 평가 완료",
                              body: "새 지적 \(o.new) · 재발 \(o.reopened) · 반복 \(o.repeated)\(rejected > 0 ? " · 버린 지적 \(rejected)" : "")",
                              dureSession: "observer:\(id)")
            case .failed(let m):
                Notifier.post(title: "\(title) 평가 실패", body: String(m.prefix(200)), dureSession: "observer:\(id)")
            case .skipped:
                // 작업 단위가 사라진 실행은 queued 로 남는다 — 그대로 pump 하면 같은 실행을 즉시 다시 집어
                // 무한 루프가 된다. 아직 queued 면 실패로 닫아 큐에서 뺀다.
                let t = self.now()
                try? await self.db.write { db in
                    guard var r = try EvaluationRun.fetchOne(db, key: id), r.status == .queued else { return }
                    r.status = .failed
                    r.finishedAt = t
                    r.failure = "작업 단위가 없다"
                    try r.update(db)
                }
            }
            self.pump()
        }
    }

    func reload() {
        units = (try? db.read { try WorkUnit.order(Column("last_ts").desc).fetchAll($0) }) ?? []
        let runs = (try? db.read { try EvaluationRun.order(Column("created_at").desc).fetchAll($0) }) ?? []
        var latest: [String: EvaluationRun] = [:]
        for r in runs where latest[r.unitId] == nil { latest[r.unitId] = r }
        latestRun = latest
        backlog = BacklogRules.ranked((try? db.read { try BacklogItem.fetchAll($0) }) ?? [])
        formatWarning = (try? db.read { try ObsCollector.formatWarning(in: $0) }) ?? false
        unknownTypes = (try? db.read { try ObsCollector.unknownTypeCount(in: $0) }) ?? 0
    }

    // MARK: - 조회 · 조작

    /// "토큰" 탭을 열 때 한 번 읽는다(수집 틱마다 다시 셀 일이 아니다).
    func tokenComparison() -> [TokenAccounting.RepoComparison] {
        (try? db.read { try TokenAccounting.comparison(in: $0) }) ?? []
    }

    /// 어느 배분에도 귀속되지 않은 조율자 토큰 — 표의 두레 쪽 수치에 안 잡히는 몫.
    func unattributedOrchestrator() -> [TokenAccounting.Unattributed] {
        (try? db.read { try TokenAccounting.unattributed(in: $0) }) ?? []
    }

    func runs(forUnit id: String) -> [EvaluationRun] {
        (try? db.read { try EvaluationRun.filter(Column("unit_id") == id).order(Column("created_at").desc).fetchAll($0) }) ?? []
    }

    func findings(forRun id: String) -> [Finding] {
        (try? db.read { try Finding.filter(Column("run_id") == id).order(Column("severity").desc).fetchAll($0) }) ?? []
    }

    func findings(forKey key: String) -> [Finding] {
        (try? db.read { try Finding.filter(Column("backlog_key") == key).order(Column("observed_at").desc).fetchAll($0) }) ?? []
    }

    func report(unit: String, run: String) -> String? {
        try? String(contentsOf: dirs.runDir(unit: unit, run: run).appendingPathComponent("report.md"), encoding: .utf8)
    }

    func isStale(_ unit: WorkUnit) -> Bool {
        guard let r = latestRun[unit.id], r.status == .done else { return false }
        return ObserverRules.isStale(unit: unit, run: r)
    }

    func setState(_ key: String, _ state: BacklogState, linkedIssue: String? = nil) {
        let t = now()
        try? db.write { try BacklogStore.setState(key, state, linkedIssue: linkedIssue, now: t, in: $0) }
        reload()
    }

    func setFeedback(_ findingID: String, _ feedback: FindingFeedback?) {
        let t = now()
        try? db.write { try BacklogStore.setFeedback(findingID: findingID, feedback, now: t, in: $0) }
        reload()
    }

    struct ChatPane: Equatable {
        var unitID: String
        var script: String
    }

    /// 같은 작업의 대화가 이미 열려 있으면 아무것도 하지 않는다 — 새 세션 행 · 새 claude 를 만들지 않는다.
    /// 다른 작업이면 바꾼다(확인은 화면이 받는다). 옛 페인은 뷰가 걷히면서 프로세스가 끝난다.
    func openChat(_ unitID: String) {
        guard chat?.unitID != unitID, let script = chatScript(for: unitID) else { return }
        chat = ChatPane(unitID: unitID, script: script)
    }

    func closeChat() { chat = nil }

    /// 리포트에 대해 묻기 — 최신 완료 실행 폴더에서, 평가와 같은 격리로. 세션 ID 는 수집에서 빠지도록 먼저 적는다.
    func chatScript(for unitID: String) -> String? {
        guard let run = runs(forUnit: unitID).first(where: { $0.status == .done }) else { return nil }
        let sid = UUID().uuidString.lowercased(), t = now()
        try? db.write { try ObserverSession(sessionId: sid, kind: "chat", createdAt: t).insert($0) }
        let transcripts = (try? db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT transcript_path FROM obs_turn WHERE unit_id = ?", arguments: [unitID])
        }) ?? []
        let unit = units.first { $0.id == unitID }
        var add = [dirs.reference.path]
        if let root = unit?.repoRoot { add.append(root) }
        add += Set(transcripts.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        return Spawn.script(cwd: dirs.runDir(unit: unitID, run: run.id).path, sessionID: sid,
                            settingsPath: dirs.chatSettings.path, sessionName: "dure-감시자",
                            addDirs: add.filter { FileManager.default.fileExists(atPath: $0) },
                            initialPrompt: "이 작업 리포트에 대해 이야기하자. report.md 와 digest.md 를 먼저 읽어라. 원본이 필요하면 digest.md 의 참조 경로를 읽어라. 고치지는 않는다 — 읽고 설명한다.",
                            extraArgs: EvalSpec.isolationArgs(sessionID: sid))
    }
}
