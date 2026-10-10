// Dure/Dure/Observer/TokenAccounting.swift
import Foundation
import GRDB

/// "두레를 쓰면 기존 방식보다 토큰이 과하게 드나"(D-34 보강 · D-36). 금액이 아니라 청구 기준 토큰(캐시 읽기 제외).
/// 레포 페인의 일은 터미널에서도 했을 일 — **추가분은 조율자 몫**이고, 비교 상대는 같은 레포의 **터미널 전용 이슈 작업 중앙값**.
nonisolated enum TokenAccounting {

    static let window = 3600

    struct Breakdown: Equatable, Sendable {
        var repo = 0, subagent = 0, orchestrator = 0
        /// 세션마다 첫 턴의 캐시 생성 — 세션을 새로 열 때마다 드는 고정비.
        var sessionStart = 0
        var cacheRead = 0
        /// 사람 턴 + 배분 받은 턴.
        var turns = 0
        var linesChanged: Int?

        var total: Int { repo + subagent + orchestrator }
        var orchestratorShare: Double { total == 0 ? 0 : Double(orchestrator) / Double(total) }
        var perTurn: Double? { turns > 0 ? Double(total) / Double(turns) : nil }
        var perLine: Double? { linesChanged.flatMap { $0 > 0 ? Double(total) / Double($0) : nil } }
    }

    struct Baseline: Equatable, Sendable {
        var samples: Int
        var perTurn: Double?
        var perLine: Double?
        /// 변경 줄은 평가된 작업에만 있어 `samples` 보다 적다 — 줄당 수치의 실제 표본 수.
        var perLineSamples = 0
        /// 작업 종류가 섞여 있어 표본이 적으면 배수가 의미 없다.
        var isReliable: Bool { samples >= 3 }
    }

    struct UnitTotals: Equatable, Sendable {
        var unitId: String
        var repoRoot: String
        var workspaceId: String?
        var firstTs: Int
        var lastTs: Int
        var tokens: Int
        var turns: Int
        var linesChanged: Int?
        var usedDure: Bool
    }

    struct RepoComparison: Equatable, Sendable, Identifiable {
        var repoRoot: String
        var terminal: Baseline
        var dure: Baseline
        var orchestratorShare: Double?
        var id: String { repoRoot }
        var ratio: Double? {
            guard terminal.isReliable, dure.isReliable else { return nil }
            return TokenAccounting.ratio(dure.perTurn, terminal.perTurn)
        }
    }

    static func targets(of turn: ObsTurn, tools: [ObsTool]) -> [String] {
        var out = tools.filter { $0.turnId == turn.id && $0.name == "mcp__dure__dispatch" }.compactMap(\.target)
        var rest = Substring(turn.prompt)
        while let open = rest.firstIndex(of: "‹"), let close = rest[open...].firstIndex(of: "›") {
            out.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        var seen: Set<String> = []
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    static func names(repoPath: String, label: String?) -> Set<String> {
        Set([label, (repoPath as NSString).lastPathComponent, repoPath].compactMap { $0?.lowercased() })
    }

    static func orchestratorShare(for repoRoot: String, label: String?, orchestratorTurns: [ObsTurn], tools: [ObsTool]) -> Int {
        let mine = names(repoPath: repoRoot, label: label)
        var total = 0
        for t in orchestratorTurns {
            let tg = targets(of: t, tools: tools)
            let hits = tg.filter { mine.contains($0.lowercased()) }.count
            if hits > 0 { total += (t.tokensHeadline + t.sidechainTokens) * hits / tg.count }
        }
        return total
    }

    static func breakdown(unit: WorkUnit, turns: [ObsTurn], orchestratorTurns: [ObsTurn], orchestratorTools: [ObsTool],
                          repoLabel: String?) -> Breakdown {
        var b = Breakdown()
        b.repo = turns.map(\.tokensHeadline).reduce(0, +)
        b.subagent = turns.map(\.sidechainTokens).reduce(0, +)
        b.cacheRead = turns.map(\.tokensCacheRead).reduce(0, +)
        b.turns = unit.activity
        b.linesChanged = unit.linesChanged
        b.sessionStart = Dictionary(grouping: turns, by: \.ccSessionId).values
            .compactMap { $0.min { ($0.ts, $0.lineNo) < ($1.ts, $1.lineNo) } }.map(\.tokensCacheCreation).reduce(0, +)
        if let root = unit.repoRoot {
            b.orchestrator = orchestratorShare(for: root, label: repoLabel, orchestratorTurns: orchestratorTurns, tools: orchestratorTools)
        }
        return b
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func ratio(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, b > 0 else { return nil }
        return a / b
    }

    static func baseline(_ units: [UnitTotals]) -> Baseline {
        let perLine = units.compactMap { u in u.linesChanged.flatMap { $0 > 0 ? Double(u.tokens) / Double($0) : nil } }
        return Baseline(samples: units.count,
                 perTurn: median(units.filter { $0.turns > 0 }.map { Double($0.tokens) / Double($0.turns) }),
                 perLine: median(perLine),
                 perLineSamples: perLine.count)
    }

    /// 이슈 브랜치 작업의 레포 + 서브에이전트 토큰. 조율자 몫은 여기 없다 — 두레 쪽은 `comparison` 이 더한다.
    /// 두레 사용 = 두레 페인 턴이나 배분으로 받은 턴이 하나라도 있음.
    static func unitTotals(repoRoot: String?, in db: Database) throws -> [UnitTotals] {
        var sql = """
            SELECT u.id, u.repo_root, u.workspace_id, u.first_ts, u.last_ts, u.human_turns + u.peer_turns AS turns, u.lines_changed,
                   SUM(t.tokens_input + t.tokens_cache_creation + t.tokens_output + t.sidechain_tokens) AS tok,
                   MAX(CASE WHEN t.origin = 'terminal' AND t.prompt_kind != 'peer' THEN 0 ELSE 1 END) AS dure
            FROM work_unit u JOIN obs_turn t ON t.unit_id = u.id
            WHERE u.kind = 'issue_branch' AND u.human_turns + u.peer_turns > 0 AND u.repo_root IS NOT NULL
            """
        var args: StatementArguments = []
        if let repoRoot { sql += " AND u.repo_root = ?"; args += [repoRoot] }
        sql += " GROUP BY u.id"
        return try Row.fetchAll(db, sql: sql, arguments: args).map { r in
            UnitTotals(unitId: r["id"], repoRoot: r["repo_root"], workspaceId: r["workspace_id"], firstTs: r["first_ts"],
                       lastTs: r["last_ts"], tokens: r["tok"] ?? 0, turns: r["turns"], linesChanged: r["lines_changed"],
                       usedDure: (r["dure"] as Int? ?? 0) == 1)
        }
    }

    /// 감시자 창 "토큰" 탭. 시간 창이 겹치는 같은 레포 작업이 둘이면 같은 조율자 턴이 양쪽에 들어간다 — 참고치라 받아들인다.
    static func comparison(in db: Database) throws -> [RepoComparison] {
        let totals = try unitTotals(repoRoot: nil, in: db)
        guard !totals.isEmpty else { return [] }
        let labels: [String: String?] = Dictionary(try Row.fetchAll(db, sql: "SELECT path, label FROM repo")
            .map { ($0["path"] as String, $0["label"] as String?) }, uniquingKeysWith: { a, _ in a })
        let orchUnits = try WorkUnit.filter(Column("kind") == UnitKind.orchestrator.rawValue).fetchAll(db)
        let wsOf = Dictionary(uniqueKeysWithValues: orchUnits.map { ($0.id, $0.workspaceId) })
        let orchTurns = orchUnits.isEmpty ? [] : try ObsTurn.filter(orchUnits.map(\.id).contains(Column("unit_id"))).fetchAll(db)
        // 서브에이전트가 한 배분도 센다 — 같은 턴 안의 중복은 targets() 가 걷어낸다.
        let tools = try ObsTool.filter(Column("name") == "mcp__dure__dispatch").fetchAll(db)

        return Dictionary(grouping: totals, by: \.repoRoot).sorted { $0.key < $1.key }.map { root, units in
            var dureUnits: [UnitTotals] = []
            var orchSum = 0, dureSum = 0
            for var u in units where u.usedDure {
                // 창 끝을 늘리는 이유: "배분 #N 끝남" 보고를 받는 조율자 턴은 레포 작업의 마지막 턴 뒤에 온다.
                let inWindow = orchTurns.filter {
                    u.workspaceId != nil && wsOf[$0.unitId] == u.workspaceId && $0.ts >= u.firstTs - window && $0.ts <= u.lastTs + window
                }
                let o = orchestratorShare(for: root, label: labels[root] ?? nil, orchestratorTurns: inWindow, tools: tools)
                u.tokens += o
                orchSum += o
                dureSum += u.tokens
                dureUnits.append(u)
            }
            return RepoComparison(repoRoot: root, terminal: baseline(units.filter { !$0.usedDure }), dure: baseline(dureUnits),
                                  orchestratorShare: dureSum > 0 ? Double(orchSum) / Double(dureSum) : nil)
        }
    }

    struct Unattributed: Equatable, Sendable, Identifiable {
        var workspaceId: String
        var name: String?
        var tokens: Int
        var id: String { workspaceId }
    }

    /// 어느 두레 사용 작업에도 귀속되지 않은 조율자 토큰(상의만 한 턴 · 대상 불명 · 창 밖). 표에 안 보이는 두레 비용이라 따로 보여준다.
    static func unattributed(in db: Database) throws -> [Unattributed] {
        let orchUnits = try WorkUnit.filter(Column("kind") == UnitKind.orchestrator.rawValue).fetchAll(db)
        guard !orchUnits.isEmpty else { return [] }
        let wsOf = Dictionary(uniqueKeysWithValues: orchUnits.map { ($0.id, $0.workspaceId) })
        let turns = try ObsTurn.filter(orchUnits.map(\.id).contains(Column("unit_id"))).fetchAll(db)
        let tools = try ObsTool.filter(Column("name") == "mcp__dure__dispatch").fetchAll(db)
        let labels: [String: String?] = Dictionary(try Row.fetchAll(db, sql: "SELECT path, label FROM repo")
            .map { ($0["path"] as String, $0["label"] as String?) }, uniquingKeysWith: { a, _ in a })
        let units = try unitTotals(repoRoot: nil, in: db).filter(\.usedDure)
        var sums: [String: Int] = [:]
        for t in turns {
            guard let ws = wsOf[t.unitId] ?? nil else { continue }
            let tg = targets(of: t, tools: tools)
            let tok = t.tokensHeadline + t.sidechainTokens
            // orchestratorShare 가 `tok * hits / tg.count` 로 나누므로 여기도 같은 비율로 — 대상 중 맞는 작업이 없는 몫만 남긴다.
            let unmatched = tg.filter { target in
                !units.contains { u in
                    u.workspaceId == ws && t.ts >= u.firstTs - window && t.ts <= u.lastTs + window
                        && names(repoPath: u.repoRoot, label: labels[u.repoRoot] ?? nil).contains(target.lowercased())
                }
            }.count
            sums[ws, default: 0] += tg.isEmpty ? tok : tok * unmatched / tg.count
        }
        return try sums.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { ws, tok in
            Unattributed(workspaceId: ws, name: try String.fetchOne(db, sql: "SELECT name FROM workspace WHERE id = ?", arguments: [ws]),
                         tokens: tok)
        }
    }
}
