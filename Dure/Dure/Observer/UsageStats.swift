// Dure/Dure/Observer/UsageStats.swift
import Foundation
import GRDB

/// 대시보드 ③ — 워크스페이스 레포별(+ 조율자) 토큰 · 툴 호출 수와 툴 에러 상위. 이슈 #35.
///
/// **감시자 수집 표만 쓴다** — 레포 경로 기준이라 두레 페인이든 터미널에서 직접 띄운 세션이든 센다.
/// F6/F7 표(`token_usage` · `tool_use`)는 두레 페인 세션만 들어 있어 쓰지 않는다.
/// 습관 분석은 감시자 평가 몫이다. 여기는 숫자 두 가지만 한다.
nonisolated enum UsageStats {

    enum Period: String, CaseIterable, Sendable {
        case today, week, all

        /// 이 시각 이후만 센다. `nil` 이면 전체. 7일은 오늘 포함 7일(6일 전 로컬 자정부터).
        func since(now: Int, timeZone: TimeZone) -> Int? {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let midnight = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
            switch self {
            case .today: return Int(midnight.timeIntervalSince1970)
            case .week: return cal.date(byAdding: .day, value: -6, to: midnight).map { Int($0.timeIntervalSince1970) }
            case .all: return nil
            }
        }
    }

    struct Usage: Equatable, Sendable {
        var tokens = 0
        var tools = 0
    }

    struct ToolError: Equatable, Sendable {
        /// 툴 이름. MCP 툴은 서버 이름 — 같은 원인(예: 호출 한도)이 툴마다 갈리지 않게.
        var source: String
        var head: String
        var count: Int
        var lastTs: Int
    }

    struct Summary: Equatable, Sendable {
        /// 레포 경로 → 사용량. 넘겨받은 경로는 전부 키로 있다(없으면 0).
        var byRepoPath: [String: Usage]
        var orchestrator: Usage
        /// 상위 10. 횟수 내림차순, 같으면 최근 먼저.
        var errors: [ToolError]
        /// 목록에서 뺀 "종료 코드뿐인 Bash 실패" 건수.
        var bareExitExcluded: Int
    }

    static let errorLimit = 10

    // MARK: - 규칙

    /// 단위의 레포 루트가 이 레포인가 — 같거나 그 아래(중첩 git 루트). 접두사만 같은 형제 폴더(`/r/app-old`)는 아니다.
    static func belongs(repoRoot: String, to path: String) -> Bool {
        repoRoot == path || repoRoot.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    /// `mcp__<서버>__<툴>` → 서버(첫 `mcp__` 와 마지막 `__` 사이). 그 밖은 툴 이름 그대로.
    static func errorSource(tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let rest = tool.dropFirst("mcp__".count)
        guard let r = rest.range(of: "__", options: .backwards), r.lowerBound > rest.startIndex else { return tool }
        return String(rest[..<r.lowerBound])
    }

    /// 사람이 거절한 툴 호출. 툴이 실패한 게 아니다. `denied` 플래그로 거르지 않는 이유 — 분류기 거부 · 오류도
    /// `denied` 로 찍히는데 그건 허용 목록 · 환경을 고칠 일이라 남긴다.
    static func isHumanRejection(_ head: String?) -> Bool {
        guard let head else { return false }
        return head.hasPrefix("The user doesn't want to proceed with this tool use") || head == CodexObsParser.declinedHead
    }

    /// 첫 줄이 `Exit code <숫자>` 뿐인 Bash 실패 — 무엇이 실패했는지 알 수 없고 grep 무매치 같은 정상 실패가 많다.
    static func isBareExitCode(tool: String, head: String?) -> Bool {
        guard tool == "Bash", let head, head.hasPrefix("Exit code ") else { return false }
        let n = head.dropFirst("Exit code ".count)
        return !n.isEmpty && n.allSatisfy(\.isNumber)
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    // MARK: - 집계

    static func compute(workspaceID: String, repoPaths: [String], since: Int?, in db: Database) throws -> Summary {
        var byRepo = Dictionary(uniqueKeysWithValues: repoPaths.map { ($0, Usage()) })
        var orchestrator = Usage()

        /// 이 행이 어느 칸인가 — 조율자면 `nil` 키, 레포면 그 경로. 범위 밖이면 `.none`.
        enum Slot { case orchestrator, repo(String) }
        func slot(_ row: Row) -> Slot? {
            let kind: String = row["kind"]
            if kind == UnitKind.orchestrator.rawValue {
                return (row["workspace_id"] as String?) == workspaceID ? .orchestrator : nil
            }
            guard let root: String = row["repo_root"] else { return nil }
            return repoPaths.first { belongs(repoRoot: root, to: $0) }.map(Slot.repo)
        }
        let scope = "(u.repo_root IS NOT NULL OR (u.kind = 'orchestrator' AND u.workspace_id = :ws))"

        let turns = try Row.fetchCursor(db, sql: """
            SELECT u.kind, u.repo_root, u.workspace_id,
                   t.tokens_input + t.tokens_cache_creation + t.tokens_output + t.sidechain_tokens AS tok
            FROM obs_turn t JOIN work_unit u ON u.id = t.unit_id
            WHERE \(scope) AND (:since IS NULL OR t.ts >= :since)
            """, arguments: ["ws": workspaceID, "since": since])
        while let row = try turns.next() {
            let tok: Int = row["tok"]
            switch slot(row) {
            case .orchestrator: orchestrator.tokens += tok
            case .repo(let p): byRepo[p, default: Usage()].tokens += tok
            case nil: break
            }
        }

        struct Key: Hashable { var source: String; var head: String }
        var errors: [Key: ToolError] = [:]
        var bareExit = 0
        let tools = try Row.fetchCursor(db, sql: """
            SELECT u.kind, u.repo_root, u.workspace_id, o.name, o.is_error, o.error_head, o.started_ts
            FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id JOIN work_unit u ON u.id = t.unit_id
            WHERE \(scope) AND (:since IS NULL OR o.started_ts >= :since)
            """, arguments: ["ws": workspaceID, "since": since])
        while let row = try tools.next() {
            guard let s = slot(row) else { continue }
            switch s {
            case .orchestrator: orchestrator.tools += 1
            case .repo(let p): byRepo[p, default: Usage()].tools += 1
            }
            guard row["is_error"] as Bool else { continue }
            let name: String = row["name"], head: String? = row["error_head"], ts: Int = row["started_ts"]
            if isHumanRejection(head) { continue }
            if isBareExitCode(tool: name, head: head) { bareExit += 1; continue }
            let key = Key(source: errorSource(tool: name), head: head ?? "")
            var e = errors[key] ?? ToolError(source: key.source, head: key.head, count: 0, lastTs: ts)
            e.count += 1
            e.lastTs = max(e.lastTs, ts)
            errors[key] = e
        }

        let top = errors.values
            .sorted { ($0.count, $0.lastTs) > ($1.count, $1.lastTs) }
            .prefix(errorLimit)
        return Summary(byRepoPath: byRepo, orchestrator: orchestrator, errors: Array(top), bareExitExcluded: bareExit)
    }
}
