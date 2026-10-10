// Dure/Dure/Observer/ObsCollector.swift
import Foundation
import GRDB

nonisolated struct CollectConfig: Sendable {
    var projectsDir: URL
    /// 감시자 자신의 폴더가 반드시 들어 있어야 한다(`ObserverDirs.collectExcludes`).
    var excludes: [String]
    var workspacesRoot: String
    var timeZone: TimeZone = .current
    /// 한 트랜잭션에 넣을 줄 수. 공유 DB 를 오래 잡아 훅 · 배분 · UI 를 막지 않게(리뷰 P1-H).
    var chunk: Int = 300
}

/// `~/.claude/projects` → 감시자 표. 스펙 v2 2절. **백그라운드에서 돈다.**
/// 턴을 넘나드는 상태는 메모리에 두지 않고 DB 에서 다시 찾는다 — 배치 경계 · 앱 재시작에 강하다.
nonisolated enum ObsCollector {

    struct Report: Equatable, Sendable {
        var filesRead = 0, turns = 0, badLines = 0, unknownTypes = 0
        static func += (a: inout Report, b: Report) {
            a.filesRead += b.filesRead; a.turns += b.turns; a.badLines += b.badLines; a.unknownTypes += b.unknownTypes
        }
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// 틱 수집과 평가 직전 flush 가 겹치면 같은 파일 커서가 엇갈린다 — 한 번에 하나.
    private static let gate = NSLock()

    static func jsonlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        func list(_ u: URL) -> [URL] { (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] }
        // 본 세션 파일을 먼저, 서브에이전트 파일을 뒤에 — 서브에이전트 줄은 부모 턴이 이미 있어야 붙는다.
        var mains: [URL] = [], subs: [URL] = []
        for project in list(dir) {
            for entry in list(project) {
                if entry.pathExtension == "jsonl" { mains.append(entry); continue }
                subs += list(entry.appendingPathComponent("subagents")).filter { $0.pathExtension == "jsonl" }
            }
        }
        return mains + subs
    }

    static func collect(db: DatabaseQueue, config: CollectConfig, resolver: RepoResolving) throws -> Report {
        gate.lock(); defer { gate.unlock() }
        let excluded = Set(try db.read { try String.fetchAll($0, sql: "SELECT session_id FROM observer_session") })
        var total = Report()
        for f in jsonlFiles(in: config.projectsDir) {
            total += try ingest(file: f, db: db, config: config, resolver: resolver, excludedSessions: excluded)
        }
        return total
    }

    static func formatWarning(in db: Database) throws -> Bool {
        let row = try Row.fetchOne(db, sql: "SELECT SUM(recent_bad) AS b, SUM(recent_total) AS t FROM obs_cursor")
        let bad: Int = row?["b"] ?? 0, total: Int = row?["t"] ?? 0
        return total >= 200 && Double(bad) / Double(total) > 0.2
    }

    static func unknownTypeCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(unknown_types), 0) FROM obs_cursor") ?? 0
    }

    static func ingest(file: URL, db: DatabaseQueue, config: CollectConfig, resolver: RepoResolving,
                       excludedSessions: Set<String> = []) throws -> Report {
        let path = file.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let cursor = try db.read { try ObsCursor.fetchOne($0, key: path) }
        if let cursor, cursor.mtime == mtime, cursor.size == size { return Report() }

        let fingerprint = firstLineUUID(path)
        var offset = cursor?.byteOffset ?? 0, lineNo = cursor?.lineNo ?? 0
        if let old = cursor?.fingerprint, old != fingerprint { offset = 0; lineNo = 0 }   // 교체된 파일
        guard let batch = TranscriptReader.read(path: path, offset: offset, lineNo: lineNo) else { return Report() }

        // 1. 트랜잭션 밖: 파싱 · 레포 조회(git 프로세스)
        let parsed = batch.lines.map { (no: $0.no, events: ObsParser.parse($0.data)) }
        var repos: [String: RepoInfo?] = [:]
        for line in parsed {
            for e in line.events ?? [] {
                if case let .turnStart(ctx, _, _, _) = e, repos[ctx.cwd] == nil { repos[ctx.cwd] = .some(resolve(ctx, resolver)) }
            }
        }

        // 2. 짧은 트랜잭션
        var report = Report(filesRead: 1)
        var state = FileState(path: path)
        var start = 0
        while start < parsed.count {
            let slice = parsed[start..<min(start + max(config.chunk, 1), parsed.count)]
            try db.write { db in
                for line in slice {
                    guard let events = line.events else { report.badLines += 1; continue }
                    for e in events {
                        switch try apply(e, lineNo: line.no, state: &state, repos: repos, excluded: excludedSessions,
                                         db: db, config: config) {
                        case .turn: report.turns += 1
                        case .unknown: report.unknownTypes += 1
                        case .none: break
                        }
                    }
                }
                try flushTouched(&state, db: db)
            }
            start += max(config.chunk, 1)
        }

        // 3. 커서
        try db.write { db in
            var bad = (cursor?.recentBad ?? 0) + report.badLines, total = (cursor?.recentTotal ?? 0) + batch.lines.count
            if total > 2000 { bad /= 2; total /= 2 }
            try ObsCursor(path: path, byteOffset: batch.byteOffset, lineNo: batch.lineNo, mtime: mtime, size: size,
                          fingerprint: fingerprint, recentBad: bad, recentTotal: total,
                          unknownTypes: (cursor?.unknownTypes ?? 0) + report.unknownTypes).save(db)
        }
        return report
    }

    // MARK: - 반영

    private struct FileState {
        let path: String
        var turnID: String?
        var looked = false
        /// 이 청크에서 처음 건드린 턴의 갱신 전 모습과 본 가장 늦은 시각. 청크 끝에서 최종값과 비교한다.
        var touched: [String: (before: TurnSig, ts: Int)] = [:]
    }

    /// 평가 입력이 되는 턴 필드(답 꼬리 · 모델 · 길이 · 중단 · 압축). 토큰은 따로 센다.
    private struct TurnSig: Equatable {
        let tail: String?, model: String?, duration: Int?, interrupted: Bool, compacted: Bool
        init(_ t: ObsTurn) {
            tail = t.answerTail; model = t.model; duration = t.durationMs; interrupted = t.interrupted; compacted = t.compacted
        }
    }

    /// 줄마다 비교하면 처음부터 다시 읽을 때 답 꼬리가 "끝" → "빌드할게" → "끝" 으로 오가며 매번 바뀐 것으로 보인다.
    /// 청크 단위로 처음과 끝만 비교해, 다시 읽기는 같은 최종값이라 올리지 않고 진짜 새 줄은 한 번만 올린다.
    private static func touch(_ turn: ObsTurn, ts: Int, _ state: inout FileState) {
        let prior = state.touched[turn.id]
        state.touched[turn.id] = (prior?.before ?? TurnSig(turn), max(prior?.ts ?? ts, ts))
    }

    private static func flushTouched(_ state: inout FileState, db: Database) throws {
        defer { state.touched = [:] }
        for (id, t) in state.touched {
            guard let now = try ObsTurn.fetchOne(db, key: id), TurnSig(now) != t.before else { continue }
            try bump(now.unitId, ts: t.ts, edit: false, db: db)
        }
    }

    private enum Applied { case none, turn, unknown }

    private static func apply(_ e: ObsParser.Event, lineNo: Int, state: inout FileState, repos: [String: RepoInfo?],
                              excluded: Set<String>, db: Database, config: CollectConfig) throws -> Applied {
        func skip(_ ctx: ObsParser.Context) -> Bool {
            excluded.contains(ctx.sessionId) || WorkUnitRules.isExcluded(cwd: ctx.cwd, prefixes: config.excludes)
        }
        switch e {
        case let .turnStart(ctx, prompt, kind, mode):
            state.looked = true
            if skip(ctx) { state.turnID = nil; return .none }
            // 다시 읽은 사건이면 빈 단위를 만들지 않도록 단위 조회보다 먼저 거른다.
            let eventId = ctx.eventId ?? "\(state.path):\(lineNo)"
            if let existing = try ObsTurn.filter(Column("event_id") == eventId).fetchOne(db) {
                state.turnID = existing.id
                return .none
            }
            var unit = try unitFor(ctx, repo: repos[ctx.cwd] ?? nil, db: db, config: config)
            let turn = ObsTurn(unitId: unit.id, eventId: eventId, ccSessionId: ctx.sessionId, transcriptPath: state.path,
                               lineNo: lineNo, origin: try origin(ctx, db: db, config: config), promptKind: kind,
                               entrypoint: ctx.entrypoint, ts: ctx.ts, prompt: String(prompt.prefix(8000)), permissionMode: mode)
            try turn.insert(db, onConflict: .ignore)
            let stored = try ObsTurn.filter(Column("event_id") == eventId).fetchOne(db)
            state.turnID = stored?.id
            guard stored?.id == turn.id else { return .none }          // 다시 읽은 사건
            unit.firstTs = min(unit.firstTs, ctx.ts)
            unit.lastTs = max(unit.lastTs, ctx.ts)
            switch kind {
            case .human: unit.humanTurns += 1
            case .peer: unit.peerTurns += 1
            case .sdk: break
            }
            unit.sourceRevision += 1
            try unit.update(db)
            return .turn

        case let .toolUse(ctx, id, name, target):
            if skip(ctx) { return .none }
            if ctx.isSidechain {
                guard let parent = try parentTurn(ctx, db: db) else { return .none }
                // 재읽기(크래시 · 파일 축소 · 지문 변경)에 카운터가 부풀지 않게, 기존 유니크 키
                // (경로, tool_use_id)로 한 번만 센다. 결과 줄은 아래 toolResult 가 같은 키로 갱신한다.
                try ObsTool(turnId: parent.id, transcriptPath: state.path, toolUseId: id, name: name, target: target,
                            startedTs: ctx.ts).insert(db, onConflict: .ignore)
                guard db.changesCount > 0 else { return .none }
                try db.execute(sql: "UPDATE obs_turn SET sidechain_tools = sidechain_tools + 1 WHERE id = ?", arguments: [parent.id])
                // 파일 수정은 누가 했든 단위의 자격(editCount)에 센다(리뷰 P8).
                try bump(parent.unitId, ts: ctx.ts, edit: editTools.contains(name), db: db)
                return .none
            }
            guard let turn = try currentTurn(&state, db: db) else { return .none }
            try ObsTool(turnId: turn.id, transcriptPath: state.path, toolUseId: id, name: name, target: target,
                        startedTs: ctx.ts).insert(db, onConflict: .ignore)
            if db.changesCount > 0 { try bump(turn.unitId, ts: ctx.ts, edit: editTools.contains(name), db: db) }
            return .none

        case let .toolResult(ts, toolUseId, isError, errorHead, denied):
            try db.execute(sql: """
                UPDATE obs_tool SET result_ts = ?, is_error = ?, error_head = ?, denied = ?
                WHERE transcript_path = ? AND tool_use_id = ?
                  AND (result_ts IS NOT ? OR is_error IS NOT ? OR error_head IS NOT ? OR denied IS NOT ?)
                """, arguments: [ts, isError, errorHead, denied, state.path, toolUseId, ts, isError, errorHead, denied])
            // 평가는 결과(실패 · 거부)를 근거로 삼는다 — 값이 실제로 바뀐 때만 단위를 "바뀜" 으로 표시한다.
            // 같은 줄을 다시 읽으면 바뀐 게 없어 올리지 않는다(멱등). 서브에이전트 행도 turn_id 로 같은 길을 탄다.
            if db.changesCount > 0,
               let unitId = try String.fetchOne(db, sql: """
                   SELECT t.unit_id FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id
                   WHERE o.transcript_path = ? AND o.tool_use_id = ?
                   """, arguments: [state.path, toolUseId]) {
                try bump(unitId, ts: ts, edit: false, db: db)
            }
            return .none

        case let .assistant(ctx, text, messageId, model, usage):
            if skip(ctx) { return .none }
            let target = ctx.isSidechain ? try parentTurn(ctx, db: db) : try currentTurn(&state, db: db)
            guard var turn = target else { return .none }
            var counted = false
            if let messageId {
                try ObsUsage(ccSessionId: ctx.sessionId, messageId: messageId, turnId: turn.id, sidechain: ctx.isSidechain)
                    .insert(db, onConflict: .ignore)
                if db.changesCount > 0 {
                    counted = true
                    if ctx.isSidechain {
                        turn.sidechainTokens += usage.headline
                    } else {
                        turn.tokensInput += usage.input
                        turn.tokensOutput += usage.output
                        turn.tokensCacheCreation += usage.cacheCreation
                        turn.tokensCacheRead += usage.cacheRead
                    }
                }
            }
            if !ctx.isSidechain {
                touch(turn, ts: ctx.ts, &state)
                if let text { turn.answerTail = String(text.suffix(500)) }
                if let model { turn.model = model }
            }
            try turn.update(db)
            // 답 꼬리 · 모델 변화는 청크 끝(flushTouched)에서 비교한다.
            if counted { try bump(turn.unitId, ts: ctx.ts, edit: false, db: db) }
            return .none

        case let .turnDuration(ms):
            guard var turn = try currentTurn(&state, db: db) else { return .none }
            touch(turn, ts: turn.ts, &state)
            turn.durationMs = ms
            try turn.update(db)
            return .none
        case .interrupted:
            guard var turn = try currentTurn(&state, db: db) else { return .none }
            touch(turn, ts: turn.ts, &state)
            turn.interrupted = true
            try turn.update(db)
            return .none
        case .compacted:
            guard var turn = try currentTurn(&state, db: db) else { return .none }
            touch(turn, ts: turn.ts, &state)
            turn.compacted = true
            try turn.update(db)
            return .none
        case .unknownType:
            return .unknown
        case .ignored:
            return .none
        }
    }

    private static func bump(_ unitId: String, ts: Int, edit: Bool, db: Database) throws {
        try db.execute(sql: """
            UPDATE work_unit SET last_ts = MAX(last_ts, ?), source_revision = source_revision + 1,
                                 edit_count = edit_count + ? WHERE id = ?
            """, arguments: [ts, edit ? 1 : 0, unitId])
    }

    private static func currentTurn(_ state: inout FileState, db: Database) throws -> ObsTurn? {
        if !state.looked {
            state.looked = true
            state.turnID = try ObsTurn.filter(Column("transcript_path") == state.path)
                .order(Column("line_no").desc).fetchOne(db)?.id
        }
        guard let id = state.turnID else { return nil }
        return try ObsTurn.fetchOne(db, key: id)
    }

    /// 서브에이전트 줄은 자기 파일에 턴이 없다 — 같은 세션에서 그 시각 직전의 사람 턴에 붙인다.
    private static func parentTurn(_ ctx: ObsParser.Context, db: Database) throws -> ObsTurn? {
        try ObsTurn.filter(Column("cc_session_id") == ctx.sessionId && Column("ts") <= ctx.ts)
            .order(Column("ts").desc, Column("line_no").desc).fetchOne(db)
    }

    private static func origin(_ ctx: ObsParser.Context, db: Database, config: CollectConfig) throws -> TurnOrigin {
        // 접두 비교를 직접 하면 `workspaces-old` 같은 형제 폴더가 걸린다(리뷰 P7).
        if WorkUnitRules.isUnderWorkspaces(cwd: ctx.cwd, workspacesRoot: config.workspacesRoot) { return .dureOrchestrator }
        let known = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cc_session WHERE cc_session_id = ?)",
                                      arguments: [ctx.sessionId]) ?? false
        return known ? .dureRepo : .terminal
    }

    private static func resolve(_ ctx: ObsParser.Context, _ resolver: RepoResolving) -> RepoInfo? {
        if let r = resolver.info(forCwd: ctx.cwd) { return r }
        // 옮겨지거나 지워진 레포 — 기록된 브랜치가 있으면 그 경로를 레포로 본다(날짜 단위로 흩어지지 않게).
        if ctx.gitBranch != nil, !FileManager.default.fileExists(atPath: ctx.cwd) {
            return RepoInfo(root: ctx.cwd, defaultBranch: nil, githubRepo: nil)
        }
        return nil
    }

    private static func unitFor(_ ctx: ObsParser.Context, repo: RepoInfo?, db: Database, config: CollectConfig) throws -> WorkUnit {
        var p = WorkUnitRules.place(cwd: ctx.cwd, branch: ctx.gitBranch, repo: repo, ts: ctx.ts,
                                    timeZone: config.timeZone, workspacesRoot: config.workspacesRoot)
        if p.workspaceId == nil, let root = p.repoRoot {
            p.workspaceId = try String.fetchOne(db, sql: "SELECT workspace_id FROM repo WHERE path = ?", arguments: [root])
        }
        if let ws = p.workspaceId,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM workspace WHERE id = ?)", arguments: [ws]) != true {
            p.workspaceId = nil     // 지워진 워크스페이스 — FK 가 막는다
        }
        let siblings = try WorkUnit.filter(Column("base_key") == p.baseKey).fetchAll(db)
        switch WorkUnitRules.chooseGeneration(siblings, turnTs: ctx.ts) {
        case .existing(let u):
            return u
        case .new(let g):
            let u = WorkUnit(unitKey: p.key(generation: g), baseKey: p.baseKey, kind: p.kind, repoRoot: p.repoRoot,
                             cwd: p.cwd, branch: p.branch, generation: g, day: p.day, issueNo: p.issueNo,
                             githubRepo: repo?.githubRepo, workspaceId: p.workspaceId, firstTs: ctx.ts, lastTs: ctx.ts)
            try u.insert(db)
            return u
        }
    }

    /// 파일 지문 — 첫 줄의 `uuid`. 앞 64KB 만 읽는다.
    static func firstLineUUID(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 65_536), let nl = data.firstIndex(of: UInt8(ascii: "\n")),
              let o = try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any] else { return nil }
        return o["uuid"] as? String
    }
}
