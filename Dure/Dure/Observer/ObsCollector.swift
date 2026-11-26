// Dure/Dure/Observer/ObsCollector.swift
import Foundation
import GRDB

nonisolated struct CollectConfig: Sendable {
    var projectsDir: URL
    /// 사용자 Codex home 의 `sessions`(rollout). nil 이면 Codex 는 수집하지 않는다(테스트 · 설정).
    var codexSessionsDir: URL? = nil
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

    /// Codex `sessions/YYYY/MM/DD/rollout-*.jsonl`. 본 세션 먼저, 서브에이전트 파일 나중 — 서브에이전트는 부모 턴이
    /// 이미 있어야 붙는다. 서브에이전트인지는 파일 이름에 없어 머리(첫 줄)를 읽어 가른다.
    /// `.jsonl.zst`(오래 쉰 rollout 을 Codex 가 압축한 것)는 고르지 않는다 — macOS 기본 라이브러리에 zstd 가 없다.
    static func codexFiles(in dir: URL) -> [URL] {
        var mains: [URL] = [], subs: [URL] = []
        for f in rolloutFiles(in: dir) {
            if codexHead(f.path).state?.isSubagent == true { subs.append(f) } else { mains.append(f) }
        }
        return mains + subs
    }

    /// `rollout-*.jsonl` 을 아래 폴더까지 찾는다. 경로는 `dir` 표기 그대로(커서 열쇠가 된다), 경로 순.
    static func rolloutFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func walk(_ u: URL, depth: Int) {
            guard depth < 6 else { return }
            for entry in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    walk(entry, depth: depth + 1)
                } else if entry.pathExtension == "jsonl", entry.lastPathComponent.hasPrefix("rollout-") {
                    out.append(entry)
                }
            }
        }
        walk(dir, depth: 0)
        return out.sorted { $0.path < $1.path }
    }

    static func collect(db: DatabaseQueue, config: CollectConfig, resolver: RepoResolving) throws -> Report {
        gate.lock(); defer { gate.unlock() }
        let excluded = Set(try db.read { try String.fetchAll($0, sql: "SELECT session_id FROM observer_session") })
        var total = Report()
        var files = jsonlFiles(in: config.projectsDir)
        if let codex = config.codexSessionsDir { files += codexFiles(in: codex) }
        for f in files {
            total += try ingest(file: f, db: db, config: config, resolver: resolver, excludedSessions: excluded)
        }
        // 정합(멱등 — 옮길 게 없으면 쓰지 않는다). ① 턴을 마지막 활동 때의 브랜치 · 아는 루트로(이슈 #60)
        // ② 백필 · 앱을 꺼 둔 동안 섞인 머지 전후 턴을 나눈다 ③ 옮겨서 빈 단위를 지운다.
        try db.write { db in
            try TurnPlacement.reconcile(in: db, resolver: resolver, config: config)
            try GenerationSplit.reconcile(in: db)
            try TurnPlacement.pruneEmpty(in: db)
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

        // 파일 종류로 파서를 고른다. Claude 는 줄마다 세션을 갖고, Codex 는 머리(`session_meta`, 첫 줄)에만 있다.
        let kind: AgentKind = isCodex(file, config: config) ? .codex : .claude
        let head: (fingerprint: String?, ts: Int?, codex: CodexObsParser.State?)
        switch kind {
        case .claude:
            let first = firstLine(path)
            head = (first.uuid, first.ts, nil)
        case .codex:
            let first = codexHead(path)
            head = (first.state?.sessionId, first.ts, first.state)
        }
        let fingerprint = head.fingerprint
        var offset = cursor?.byteOffset ?? 0, lineNo = cursor?.lineNo ?? 0
        if let old = cursor?.fingerprint, old != fingerprint { offset = 0; lineNo = 0 }   // 교체된 파일

        // 세지 않는 Codex 파일 — 가져온 Claude 세션(legacy, Claude 트랜스크립트와 이중이 된다) · 부모 표시가 없는
        // 서브에이전트(본 세션으로 세지 않는다). 커서만 끝으로 옮겨 다시 읽지 않는다.
        if let codex = head.codex, codex.skip || (codex.isSubagent && codex.parentThreadId == nil) {
            try db.write { db in
                try ObsCursor(path: path, byteOffset: size, lineNo: lineNo, mtime: mtime, size: size, fingerprint: fingerprint,
                              recentBad: cursor?.recentBad ?? 0, recentTotal: cursor?.recentTotal ?? 0,
                              unknownTypes: cursor?.unknownTypes ?? 0).save(db)
            }
            return Report()
        }
        guard let batch = TranscriptReader.read(path: path, offset: offset, lineNo: lineNo) else { return Report() }

        // 1. 트랜잭션 밖: 파싱 · 레포 조회 · 브랜치 복원(git 프로세스)
        var parsed: [(no: Int, events: [ObsParser.Event]?)]
        switch kind {
        case .claude:
            parsed = batch.lines.map { (no: $0.no, events: ObsParser.parse($0.data)) }
        case .codex:
            // 이어 읽기면 머리를 다시 읽은 상태에서 시작한다(세션 · cwd). 처음부터면 머리 줄을 또 만나도 첫 것을 지킨다.
            var parser = CodexObsParser(state: head.codex ?? .init())
            parsed = batch.lines.map { (no: $0.no, events: parser.parse($0.data, lineNo: $0.no)) }
        }
        // Codex 턴은 브랜치 없이 온다(파서) — reflog 가 못 정하면 파일 머리 `session_meta.git.branch`(스레드 시작 때 값)로.
        let fallbackBranch = kind == .codex ? head.codex?.gitBranch : nil
        var repos: [String: RepoInfo?] = [:]
        var known: [String]?
        for line in parsed {
            for e in line.events ?? [] {
                guard case let .turnStart(ctx, _, _, _) = e, repos[ctx.cwd] == nil else { continue }
                if known == nil { known = try db.read { try TurnPlacement.knownRoots($0) } }
                repos[ctx.cwd] = .some(resolve(ctx, resolver, knownRoots: known ?? []))
            }
        }
        parsed = parsed.map { line in
            (no: line.no, events: line.events?.map {
                recoverBranch($0, repos: repos, resolver: resolver, fallback: fallbackBranch)
            })
        }

        // 2. 짧은 트랜잭션
        var report = Report(filesRead: 1)
        var state = FileState(path: path, firstTs: head.ts, agentKind: kind)
        switch kind {
        case .claude:
            state.pinsParent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent == "subagents"
        case .codex:
            // Codex 서브에이전트는 따로 rollout 파일이다 — Claude `subagents/` 파일처럼 파일 하나가 부모 턴 하나.
            state.pinsParent = head.codex?.isSubagent == true
            state.parentThreads = [head.codex?.parentThreadId, head.codex?.rootSessionId].compactMap { $0 }
                .filter { $0 != head.codex?.sessionId }
        }
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
            }
            start += max(config.chunk, 1)
        }

        // 부모 턴을 못 찾은 서브에이전트 파일: 부모 세션 파일이 아직 수집 전이면 커서를 올리지 않고 다음 수집에서 다시 읽는다.
        // 부모 파일이 아예 없거나 이미 수집됐는데 턴이 없으면(지워짐 · 제외된 세션) 영원히 붙잡지 않고 줄을 건너뛴다.
        if state.parentMissing {
            let parents = kind == .codex ? codexParentFiles(state.parentThreads, config: config) : claudeParentFile(path)
            if try db.read({ try parentFilePending(parents, db: $0) }) { return Report() }
        }

        // 청크마다 비교하면 경계에 걸린 턴의 중간 꼬리가 "원본" 이 되어 다시 읽기마다 두 번 올라간다 —
        // 파일 전체를 읽은 뒤 처음과 끝만 한 번 비교한다. 중간에 죽으면 커서가 안 가므로 파일 전체를 다시 읽는다.
        try db.write { db in try flushTouched(&state, db: db) }

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
        /// 파일 첫 줄의 시각. 틱마다 새 FileState 가 만들어져도 부모가 갈라지지 않게 부모 선택의 기준으로 쓴다.
        var firstTs: Int?
        /// 이 파일을 쓴 CLI — 턴 행의 `agent_kind`.
        var agentKind: AgentKind
        /// 서브에이전트 전용 파일(Claude `<세션>/subagents/x.jsonl` · Codex 서브에이전트 rollout) — 부모 턴을 파일 단위로 못 박는다.
        var pinsParent = false
        /// Codex 서브에이전트의 부모 · 루트 스레드 id. 부모 파일이 아직 수집 전인지 볼 때 쓴다.
        var parentThreads: [String] = []
        var turnID: String?
        var looked = false
        /// 서브에이전트 파일 하나는 부모 턴 하나 — 처음 정한 부모를 파일 안에서 계속 쓴다.
        /// 다음 턴이 시작된 뒤에 도착한 줄이 다음 작업으로 새는 것을 막는다.
        var parentID: String?
        /// 부모를 못 찾았다. 이후 줄도 같은 파일이므로 시도하지 않고 건너뛴다(중간에 다른 부모로 갈라지지 않게).
        var parentMissing = false
        /// 이 파일에서 처음 건드린 턴의 갱신 전 모습과 본 가장 늦은 시각. 파일 끝에서 최종값과 비교한다.
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
    /// 파일 단위로 처음과 끝만 비교해, 다시 읽기는 같은 최종값이라 올리지 않고 진짜 새 줄은 한 번만 올린다.
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
                               entrypoint: ctx.entrypoint, ts: ctx.ts, prompt: String(prompt.prefix(8000)), permissionMode: mode,
                               agentKind: state.agentKind)
            try turn.insert(db, onConflict: .ignore)
            let stored = try ObsTurn.filter(Column("event_id") == eventId).fetchOne(db)
            state.turnID = stored?.id
            guard stored?.id == turn.id else { return .none }          // 다시 읽은 사건
            unit.firstTs = min(unit.firstTs, ctx.ts)
            unit.lastTs = max(unit.lastTs, ctx.ts)
            if kind.countsAsHuman { unit.humanTurns += 1 } else if kind == .peer { unit.peerTurns += 1 }
            unit.sourceRevision += 1
            try unit.update(db)
            return .turn

        case let .toolUse(ctx, id, name, target):
            if skip(ctx) { return .none }
            if ctx.isSidechain {
                guard let parent = try subagentParent(ctx, &state, db: db) else { return .none }
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
            let target = ctx.isSidechain ? try subagentParent(ctx, &state, db: db) : try currentTurn(&state, db: db)
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
            // 답 꼬리 · 모델 변화는 파일 끝(flushTouched)에서 비교한다.
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

    /// 서브에이전트 파일의 부모 턴. 스키마를 건드리지 않고 정한다 —
    /// ① 이 수집에서 이미 정했으면 그것 ② 이 파일 경로로 저장된 obs_tool 행의 turn_id(재시작 · 이어 읽기;
    /// obs_usage 에는 경로 열이 없다) ③ 파일 첫 줄(띄운 순간)의 시각으로 고른 턴 — 틱이 갈려도 같은 답이 나온다(첫 줄을 못 읽으면 사건 시각).
    private static func subagentParent(_ ctx: ObsParser.Context, _ state: inout FileState, db: Database) throws -> ObsTurn? {
        // 옛 형식의 메인 기록 안 isSidechain 줄은 파일 단위로 못 박지 않는다 — 한 파일에 턴이 여럿이라
        // 못 박으면 뒤 턴의 사용량이 첫 턴으로 간다. 줄마다 직전 턴에 붙인다(#27 이전 동작).
        // Codex 서브에이전트 줄의 세션 id 는 루트 스레드다(파서) — 같은 규칙으로 루트 세션의 그 시각 직전 턴을 고른다.
        guard state.pinsParent else {
            return try parentTurn(ctx, ts: ctx.ts, db: db)
        }
        if state.parentMissing { return nil }
        if let id = state.parentID, let t = try ObsTurn.fetchOne(db, key: id) { return t }
        let stored = try String.fetchOne(db, sql: """
            SELECT o.turn_id FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id
            WHERE o.transcript_path = ? ORDER BY o.started_ts, o.rowid LIMIT 1
            """, arguments: [state.path])
        let parent = try stored.flatMap { try ObsTurn.fetchOne(db, key: $0) } ?? parentTurn(ctx, ts: state.firstTs ?? ctx.ts, db: db)
        guard let parent else { state.parentMissing = true; return nil }
        state.parentID = parent.id
        return parent
    }

    /// 부모 세션 파일 중 하나라도 있는데 아직 수집(커서)되지 않았는가.
    /// 있지만 읽을 수 없는 부모 파일은 틱마다 이 서브에이전트를 붙잡는다(허용).
    private static func parentFilePending(_ parents: [String], db: Database) throws -> Bool {
        for p in parents where FileManager.default.fileExists(atPath: p) {
            if try ObsCursor.fetchOne(db, key: p) == nil { return true }
        }
        return false
    }

    /// `<세션>/subagents/x.jsonl` 의 부모 세션 파일 `<세션>.jsonl`.
    private static func claudeParentFile(_ path: String) -> [String] {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard dir.lastPathComponent == "subagents" else { return [] }
        return [dir.deletingLastPathComponent().appendingPathExtension("jsonl").path]
    }

    /// Codex 부모 rollout — 파일 이름 끝의 uuid 가 스레드 id 다(실측). 날짜 폴더가 다를 수 있어 이름으로 찾는다.
    private static func codexParentFiles(_ threads: [String], config: CollectConfig) -> [String] {
        guard let dir = config.codexSessionsDir, !threads.isEmpty else { return [] }
        return rolloutFiles(in: dir).filter { f in threads.contains { f.lastPathComponent.hasSuffix("-\($0).jsonl") } }
            .map(\.path)
    }

    /// 파일이 Codex `sessions` 아래인가. `/var` ↔ `/private/var` 같은 표기 차이에 흔들리지 않게 실제 경로로 비교한다.
    static func isCodex(_ file: URL, config: CollectConfig) -> Bool {
        guard let dir = config.codexSessionsDir else { return false }
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// 서브에이전트 줄은 자기 파일에 턴이 없다 — 같은 세션에서 그 시각 직전의 사람 턴에 붙인다.
    private static func parentTurn(_ ctx: ObsParser.Context, ts: Int, db: Database) throws -> ObsTurn? {
        try ObsTurn.filter(Column("cc_session_id") == ctx.sessionId && Column("ts") <= ts)
            .order(Column("ts").desc, Column("line_no").desc).fetchOne(db)
    }

    private static func origin(_ ctx: ObsParser.Context, db: Database, config: CollectConfig) throws -> TurnOrigin {
        // 접두 비교를 직접 하면 `workspaces-old` 같은 형제 폴더가 걸린다(리뷰 P7).
        if WorkUnitRules.isUnderWorkspaces(cwd: ctx.cwd, workspacesRoot: config.workspacesRoot) { return .dureOrchestrator }
        let known = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cc_session WHERE cc_session_id = ?)",
                                      arguments: [ctx.sessionId]) ?? false
        return known ? .dureRepo : .terminal
    }

    /// 이슈 #32 — `#` 이 든 브랜치는 트랜스크립트에 `"HEAD"` 로 남는다. 턴 시작의 브랜치가 `HEAD` 이거나 없으면
    /// 그 레포 reflog 로 그 시각의 브랜치를 되살린다. 못 하면 `fallback`(Codex 파일 머리의 브랜치, `HEAD` 는 제외)을,
    /// 그것도 없으면 그대로 둔다(지금처럼 날짜 단위). Claude 는 `fallback` 이 nil — 전과 같다.
    /// 레포를 못 찾은 cwd 에는 메우지 않는다 — 단위는 어차피 레포 없음이고, 옮겨진 레포 판정(`resolve`)은 기록된 브랜치만 본다.
    static func recoverBranch(_ e: ObsParser.Event, repos: [String: RepoInfo?], resolver: RepoResolving,
                              fallback: String? = nil) -> ObsParser.Event {
        guard case .turnStart(var ctx, let prompt, let kind, let mode) = e,
              ctx.gitBranch == nil || ctx.gitBranch == "HEAD",
              let repo = repos[ctx.cwd] ?? nil else { return e }
        if let recovered = resolver.branch(atRoot: repo.root, ts: ctx.ts) {
            ctx.gitBranch = recovered
        } else if let fallback, !fallback.isEmpty, fallback != "HEAD" {
            ctx.gitBranch = fallback
        } else {
            return e
        }
        return .turnStart(ctx, prompt: prompt, kind: kind, permissionMode: mode)
    }

    static func resolve(_ ctx: ObsParser.Context, _ resolver: RepoResolving, knownRoots: [String] = [],
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> RepoInfo? {
        if let r = resolver.info(forCwd: ctx.cwd) { return r }
        // 옮겨지거나 지워진 레포 — 기록된 브랜치가 있으면 그 경로를 레포로 본다(날짜 단위로 흩어지지 않게).
        // 이미 아는 루트가 그 경로를 품으면 그 루트로(이슈 #60) — 하위 폴더에서 연 세션이 따로 단위가 되지 않게.
        if ctx.gitBranch != nil, !exists(ctx.cwd) {
            let root = TurnPlacement.normalizedRoot(ctx.cwd, known: knownRoots, exists: exists)
            return RepoInfo(root: root, defaultBranch: nil, githubRepo: nil)
        }
        return nil
    }

    private static func unitFor(_ ctx: ObsParser.Context, repo: RepoInfo?, db: Database, config: CollectConfig) throws -> WorkUnit {
        let p = WorkUnitRules.place(cwd: ctx.cwd, branch: ctx.gitBranch, repo: repo, ts: ctx.ts,
                                    timeZone: config.timeZone, workspacesRoot: config.workspacesRoot)
        return try unit(for: p, ts: ctx.ts, githubRepo: repo?.githubRepo, db: db)
    }

    /// 자리(`Placement`)의 단위 — 같은 자리의 세대 규칙으로 고르고, 없으면 만든다. 수집과 턴 재배치(`TurnPlacement`)가 같이 쓴다.
    static func unit(for placement: WorkUnitRules.Placement, ts: Int, githubRepo: String?, db: Database) throws -> WorkUnit {
        var p = placement
        if p.workspaceId == nil, let root = p.repoRoot {
            p.workspaceId = try String.fetchOne(db, sql: "SELECT workspace_id FROM repo WHERE path = ?", arguments: [root])
        }
        if let ws = p.workspaceId,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM workspace WHERE id = ?)", arguments: [ws]) != true {
            p.workspaceId = nil     // 지워진 워크스페이스 — FK 가 막는다
        }
        let siblings = try WorkUnit.filter(Column("base_key") == p.baseKey).fetchAll(db)
        switch WorkUnitRules.chooseGeneration(siblings, turnTs: ts) {
        case .existing(let u):
            return u
        case .new(let g):
            let u = WorkUnit(unitKey: p.key(generation: g), baseKey: p.baseKey, kind: p.kind, repoRoot: p.repoRoot,
                             cwd: p.cwd, branch: p.branch, generation: g, day: p.day, issueNo: p.issueNo,
                             githubRepo: githubRepo, workspaceId: p.workspaceId, firstTs: ts, lastTs: ts)
            try u.insert(db)
            return u
        }
    }

    /// 파일 지문 — 첫 줄의 `uuid`. 앞 64KB 만 읽는다.
    static func firstLineUUID(_ path: String) -> String? { firstLine(path).uuid }

    /// Codex rollout 머리(`session_meta`, 첫 줄)와 그 시각. 머리는 지시문(`base_instructions`) 때문에 길어(실측 27KB)
    /// 줄 끝까지 읽는다 — 64KB 씩, 4MB 까지. 서브에이전트 파일의 첫 줄 시각은 띄운 순간이라 부모 턴을 고르는 기준이 된다.
    static func codexHead(_ path: String) -> (state: CodexObsParser.State?, ts: Int?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? h.close() }
        var data = Data()
        while data.count < 4 << 20 {
            guard let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty else { return (nil, nil) }   // 머리가 아직 다 안 써졌다
            let from = data.count
            data.append(chunk)
            if let nl = data[from...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = data[data.startIndex..<nl]
                let ts = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["timestamp"] as? String
                return (CodexObsParser.header(line), ts.flatMap(ObsParser.epoch))
            }
        }
        return (nil, nil)
    }

    /// 첫 줄의 uuid 와 시각. 서브에이전트 파일의 첫 줄은 띄운 순간의 프롬프트라, 부모 턴을 고르는 기준 시각이 된다.
    static func firstLine(_ path: String) -> (uuid: String?, ts: Int?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 65_536), let nl = data.firstIndex(of: UInt8(ascii: "\n")),
              let o = try? JSONSerialization.jsonObject(with: data[data.startIndex..<nl]) as? [String: Any] else { return (nil, nil) }
        return (o["uuid"] as? String, (o["timestamp"] as? String).flatMap(ObsParser.epoch))
    }
}
