// Dure/Dure/Observer/EvaluationJob.swift
import Foundation
import GRDB

nonisolated struct EvalEnvironment: Sendable {
    var db: DatabaseQueue
    var runner: CommandRunning
    var dirs: ObserverDirs
    var timeZone: TimeZone = .current
    var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    var newSessionID: @Sendable () -> String = { UUID().uuidString.lowercased() }
    /// 평가 직전 수집 한 번 — 사람이 [평가] 를 누른 순간까지의 기록을 스냅숏에 넣는다.
    var flush: @Sendable () -> Void = {}
}

/// 평가 실행 하나. 스펙 v2 3-2 · 5절. **백그라운드에서 돈다.**
nonisolated enum EvaluationJob {

    enum Outcome: Equatable, Sendable {
        case evaluated(BacklogStore.Outcome, rejected: Int)
        case failed(String)
        case skipped
    }

    private struct JobError: Error, CustomStringConvertible { var description: String }

    /// 같은 단위에 대기 · 실행 중인 실행이 있으면 새로 만들지 않는다.
    /// 단 **수동 요청**은 대기 중인 auto 를 manual 로 승격한다 — 자동 평가가 꺼졌거나 상한이면 auto 는 영영 안 도는데,
    /// 중복으로 거절하면 사람이 평가할 방법이 없다. 실행 중이면 승격하지 않고 nil.
    static func enqueue(unitID: String, trigger: RunTrigger, now: Int, in db: Database) throws -> EvaluationRun? {
        let busy = try EvaluationRun.filter(Column("unit_id") == unitID &&
                                            [RunStatus.queued.rawValue, RunStatus.running.rawValue].contains(Column("status")))
            .fetchAll(db)
        if trigger == .manual, !busy.contains(where: { $0.status == .running }),
           var queued = busy.first(where: { $0.status == .queued && $0.trigger == .auto }) {
            queued.trigger = .manual
            try queued.update(db)
            return queued
        }
        // 수동 대기 · 실행 중 · auto 요청의 중복은 기존 계약대로 nil.
        guard busy.isEmpty else { return nil }
        let r = EvaluationRun(unitId: unitID, trigger: trigger, status: .queued, createdAt: now)
        try r.insert(db)
        return r
    }

    /// 수집이 끝날 때마다. 머지됐는데 아직 자동 평가를 한 번도 안 넣은 단위 중 자격이 생긴 것을 auto 로 넣는다.
    /// "자동 이력" 은 trigger 가 auto 인 실행, 또는 머지 뒤에 만들어진 실행(수동 승격으로 manual 이 된 자동 몫 포함)이다.
    static func enqueueLateEligible(firstStart: Int, _ s: ObserverSettings, now: Int, in db: Database) throws -> Int {
        guard s.autoEvaluate else { return 0 }
        var n = 0
        for u in try WorkUnit.filter(Column("merged_at") != nil && Column("merged_at") >= firstStart).fetchAll(db) {
            let hasAutoRun = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM evaluation_run
                WHERE unit_id = ?1 AND ("trigger" = 'auto' OR created_at >= ?2)
                """, arguments: [u.id, u.mergedAt ?? 0]) ?? 0 > 0
            guard ObserverRules.needsAutoEvaluation(u, hasAutoRun: hasAutoRun, firstStart: firstStart, s) else { continue }
            if try enqueue(unitID: u.id, trigger: .auto, now: now, in: db) != nil { n += 1 }
        }
        return n
    }

    /// 앱 시작 때. 평가 중에 꺼진 실행은 영영 끝나지 않는다 — 닫고 같은 계기로 한 번만 다시 큐에(리뷰 P1-B).
    static func recover(now: Int, in db: Database) throws -> Int {
        let running = try EvaluationRun.filter(Column("status") == RunStatus.running.rawValue).fetchAll(db)
        for var r in running {
            r.status = .interrupted
            r.finishedAt = now
            r.failure = "앱이 평가 중에 종료됐다"
            try r.update(db)
            _ = try enqueue(unitID: r.unitId, trigger: r.trigger, now: now, in: db)
        }
        return running.count
    }

    static func run(runID: String, env: EvalEnvironment) async -> Outcome {
        let claimed: EvaluationRun?
        do {
            claimed = try await env.db.write { db -> EvaluationRun? in
                guard var r = try EvaluationRun.fetchOne(db, key: runID), r.status == .queued,
                      try WorkUnit.fetchOne(db, key: r.unitId) != nil else { return nil }
                r.status = .running
                r.startedAt = env.now()
                try r.update(db)
                return r
            }
        } catch { return .failed("\(error)") }
        guard let run = claimed else { return .skipped }

        env.flush()
        do {
            let sessionID = env.newSessionID()
            let stamp = (try? String(contentsOf: env.dirs.reference.appendingPathComponent("practices.md"), encoding: .utf8))
                .flatMap(ObserverRules.referenceDeadline)
            var (unit, input) = try await env.db.write { db -> (WorkUnit, DigestInput) in
                guard let u = try WorkUnit.fetchOne(db, key: run.unitId) else { throw JobError(description: "작업 단위가 없다") }
                let input = try gather(u, dirs: env.dirs, db: db)
                // 실행 전에 적는다 — 평가 세션이 수집돼 평가가 평가를 낳지 않게.
                try ObserverSession(sessionId: sessionID, kind: "eval", createdAt: env.now()).insert(db, onConflict: .ignore)
                var r = run
                r.sourceRevision = u.sourceRevision
                r.sessionId = sessionID
                r.promptVersion = EvalSpec.promptVersion
                r.referenceStamp = stamp
                try r.update(db)
                return (u, input)
            }
            input.timeZone = env.timeZone
            if let script = MergeWatcher.diffStatScript(unit) {
                input.diffStat = MergeWatcher.parseDiffStat(await env.runner.run(script, timeout: 60))
            }
            let lines = input.diffStat.flatMap(MergeWatcher.lines(fromStat:))
            unit.linesChanged = lines ?? unit.linesChanged
            input.tokens?.linesChanged = lines ?? unit.linesChanged

            let dir = env.dirs.runDir(unit: unit.id, run: run.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let digest = DigestBuilder.render(input)
            try digest.write(to: dir.appendingPathComponent("digest.md"), atomically: true, encoding: .utf8)
            try backlogMarkdown(try await env.db.read { try BacklogItem.fetchAll($0) })
                .write(to: dir.appendingPathComponent("backlog.md"), atomically: true, encoding: .utf8)
            try EvalPrompt.render(referenceDir: env.dirs.reference.path)
                .write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)

            let script = EvalSpec.script(runDir: dir.path, sessionID: sessionID, addDirs: addDirs(unit, input: input, dirs: env.dirs))
            let result = await env.runner.run(script, timeout: EvalSpec.timeout)
            // 앱 종료로 죽은 실행은 running 으로 둔다 — 다음 실행 때 recover 가 interrupted 로 닫고 다시 큐에 넣는다.
            if result.cancelled { return .failed("앱 종료로 평가를 멈췄다") }
            switch EvalSpec.interpret(result) {
            case .failure(let f):
                markFailed(run.id, f.message, env: env)
                return .failed(f.message)
            case .success(let out):
                let (accepted, rejected) = FindingValidator.validate(out.findings, index: EvidenceIndex(turns: input.turns, orchestratorTurns: input.orchestratorTurns))
                try ReportRenderer.render(title: unit.title, summary: out.summary, notes: out.notes, findings: accepted,
                                          rejected: rejected.count)
                    .write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                let now = env.now()
                let unitID = unit.id
                let merged = try await env.db.write { db -> BacklogStore.Outcome in
                    guard var r = try EvaluationRun.fetchOne(db, key: run.id) else { throw JobError(description: "실행 기록이 없다") }
                    r.status = .done
                    r.finishedAt = now
                    r.costUsd = out.costUSD
                    r.summary = out.summary
                    r.notes = out.notes
                    r.accepted = accepted.count
                    r.rejected = rejected.count
                    r.digestChars = digest.count
                    try r.update(db)      // done 이 먼저 — recount 가 "최신 완료 실행" 을 본다
                    if let lines {
                        try db.execute(sql: "UPDATE work_unit SET lines_changed = ? WHERE id = ?", arguments: [lines, unitID])
                    }
                    return try BacklogStore.apply(accepted, unitID: unitID, runID: run.id, now: now, in: db)
                }
                return .evaluated(merged, rejected: rejected.count)
            }
        } catch {
            markFailed(run.id, "\(error)", env: env)
            return .failed("\(error)")
        }
    }

    private static func markFailed(_ id: String, _ reason: String, env: EvalEnvironment) {
        let now = env.now()
        try? env.db.write { db in
            guard var r = try EvaluationRun.fetchOne(db, key: id) else { return }
            r.status = .failed
            r.failure = String(reason.prefix(2000))
            r.finishedAt = now
            try r.update(db)
        }
    }

    static func gather(_ u: WorkUnit, dirs: ObserverDirs, db: Database) throws -> DigestInput {
        let turns = try ObsTurn.filter(Column("unit_id") == u.id).order(Column("ts"), Column("line_no")).fetchAll(db)
        let turnIDs = turns.map(\.id)
        let tools = turnIDs.isEmpty ? [] : try ObsTool.filter(turnIDs.contains(Column("turn_id")))
            // 서브에이전트 툴은 부모 턴의 sidechainTools 가 이미 센다 — 다시 넣으면 이중 계산
            .filter(!Column("transcript_path").like("%/subagents/%")).fetchAll(db)
        let sessions = Array(Set(turns.map(\.ccSessionId)))
        let permissions = sessions.isEmpty ? [] : try ObsPermission.filter(sessions.contains(Column("cc_session_id")))
            // 같은 세션의 다른 작업 시간대 승인 요청이 섞이지 않게 단위 창으로 자른다
            .filter(Column("ts") >= u.firstTs && Column("ts") <= u.lastTs).fetchAll(db)

        // 창 끝을 늘리는 이유: 완료 보고("배분 #N 끝남")를 받는 조율자 턴은 레포 작업의 마지막 턴 뒤에 온다(조율자 몫 과소계상 방지).
        var orchestrator: [ObsTurn] = []
        if let ws = u.workspaceId, u.kind != .orchestrator {
            orchestrator = try ObsTurn.fetchAll(db, sql: """
                SELECT obs_turn.* FROM obs_turn JOIN work_unit ON work_unit.id = obs_turn.unit_id
                WHERE work_unit.kind = 'orchestrator' AND work_unit.workspace_id = ? AND obs_turn.ts BETWEEN ? AND ?
                ORDER BY obs_turn.ts
                """, arguments: [ws, u.firstTs - 3600, u.lastTs + 3600])
        }

        // 배분: 이 레포로 간 것 중 같은 시간대. delivered_session 이 "argv" 일 수 있어 레포 · 시각으로 잇는다.
        var dispatches: [DigestDispatch] = []
        if let root = u.repoRoot {
            for row in try Row.fetchAll(db, sql: """
                SELECT d.seq, d.title, d.instruction, d.state, d.created_at, d.delivered_at, d.done_at, d.result, r.label, r.path
                FROM dispatch d JOIN repo r ON r.id = d.repo_id
                WHERE r.path = ? AND d.created_at BETWEEN ? AND ? ORDER BY d.seq
                """, arguments: [root, u.firstTs - 3600, u.lastTs]) {
                let path: String = row["path"]
                dispatches.append(DigestDispatch(seq: row["seq"], repoName: row["label"] ?? (path as NSString).lastPathComponent,
                                                 title: row["title"], instruction: row["instruction"], state: row["state"],
                                                 createdAt: row["created_at"], deliveredAt: row["delivered_at"],
                                                 doneAt: row["done_at"], result: row["result"]))
            }
        }

        let fm = FileManager.default
        let transcripts = Array(Set(turns.map(\.transcriptPath))).sorted()
        var refs: [String] = []
        if let root = u.repoRoot {
            refs += ["CLAUDE.md", "AGENTS.md", ".claude/settings.local.json", ".claude/settings.json"]
                .map { (root as NSString).appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0) }
        }
        if let ws = u.workspaceId {
            let ctx = dirs.workspacesRoot.appendingPathComponent(ws).appendingPathComponent("context.md").path
            if fm.fileExists(atPath: ctx) { refs.append(ctx) }
        }
        refs += [dirs.claudeHome.appendingPathComponent("skills").path, dirs.claudeHome.appendingPathComponent("plugins").path]
        refs += transcripts

        // Task 13 — 토큰 나눔 · 기준선(같은 레포의 터미널 전용 이슈 작업, 이번 작업 제외).
        let label = try u.repoRoot.flatMap { try String.fetchOne(db, sql: "SELECT label FROM repo WHERE path = ?", arguments: [$0]) }
        let orchIDs = orchestrator.map(\.id)
        let orchTools = orchIDs.isEmpty ? [] : try ObsTool
            .filter(orchIDs.contains(Column("turn_id")) && Column("name") == "mcp__dure__dispatch").fetchAll(db)
        let tokens = TokenAccounting.breakdown(unit: u, turns: turns, orchestratorTurns: orchestrator,
                                               orchestratorTools: orchTools, repoLabel: label)
        let baseline = try u.repoRoot.map { root in
            TokenAccounting.baseline(try TokenAccounting.unitTotals(repoRoot: root, in: db).filter { $0.unitId != u.id && !$0.usedDure })
        }

        return DigestInput(unit: u, turns: turns, tools: tools, permissions: permissions, orchestratorTurns: orchestrator,
                           dispatches: dispatches, references: refs,
                           missingTranscripts: Set(transcripts.filter { !fm.fileExists(atPath: $0) }),
                           tokens: tokens, baseline: baseline)
    }

    /// 평가자가 읽을 수 있게 붙일 폴더 — **있는 것만**.
    static func addDirs(_ u: WorkUnit, input: DigestInput, dirs: ObserverDirs) -> [String] {
        var out: [String] = []
        if let root = u.repoRoot { out.append(root) }
        if let ws = u.workspaceId, !input.orchestratorTurns.isEmpty || u.kind == .orchestrator {
            out.append(dirs.workspacesRoot.appendingPathComponent(ws).path)
        }
        out += [dirs.reference.path, dirs.claudeHome.appendingPathComponent("skills").path,
                dirs.claudeHome.appendingPathComponent("plugins").path]
        out += Set(input.turns.map { ($0.transcriptPath as NSString).deletingLastPathComponent }).sorted()
        var seen: Set<String> = []
        return out.filter { p in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue && seen.insert(p).inserted
        }
    }

    static func backlogMarkdown(_ items: [BacklogItem]) -> String {
        guard !items.isEmpty else { return "# 백로그\n\n아직 없다. 모든 지적에 새 key 를 만든다.\n" }
        var o = "# 백로그 — 같은 문제면 이 key 를 그대로 쓴다\n\n"
        for i in items.sorted(by: { $0.key < $1.key }) {
            let line = i.detail.split(separator: "\n").first.map { String($0.prefix(120)) } ?? ""
            o += "- `\(i.key)` [\(i.grp) · \(i.state.rawValue) · 관찰 \(i.observedCount)회] \(i.title) — \(line)\n"
        }
        return o
    }
}
