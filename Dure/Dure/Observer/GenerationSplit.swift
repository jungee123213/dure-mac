// Dure/Dure/Observer/GenerationSplit.swift
import Foundation
import GRDB

/// 머지 경계를 뒤늦게 안 단위를 세대로 나눈다(이슈 #27 Task 4).
/// 수집은 그 순간 저장된 `merged_at` 만 보고 세대를 고른다 — 첫 수집(백필)이나 앱을 꺼 둔 동안 같은 브랜치를 다시 쓰면
/// 머지 전후 턴이 한 단위에 섞이고, 나중에 `merged_at` 을 적어도 그대로 남는다. 그래서 수집이 끝날 때와
/// 머지를 적은 직후에 이 정합 단계를 돈다. 한 트랜잭션 안에서 부른다 — 수집 · 평가가 반쯤 옮긴 상태를 보지 않게.
nonisolated enum GenerationSplit {

    /// `ts > merged_at` 인 턴을 같은 자리의 다음 세대로 옮긴다. 옮긴 턴 수를 돌려준다.
    /// 옮길 턴이 없으면 아무것도 쓰지 않는다 — 매 수집 반복돼도 revision 이 오르지 않는다(멱등).
    /// `obs_tool` · `obs_usage` · 서브에이전트 토큰은 `turn_id` 로 턴을 따라가므로 턴의 `unit_id` 만 바꾼다.
    /// 평가 실행 · 지적은 원래 단위에 둔다 — 그 실행 폴더의 당시 다이제스트가 근거다.
    @discardableResult
    static func reconcile(in db: Database) throws -> Int {
        var touched = Set<String>()
        var moved = 0
        // 한 번에 맞는 세대로 보내지만, 새로 만든 세대가 다시 걸리는 경우까지 안전하게 비울 때까지 돈다.
        // 턴은 매번 더 높은 세대로만 가므로 끝난다.
        while true {
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS turn_id, t.ts AS ts, t.unit_id AS unit_id FROM obs_turn t
                JOIN work_unit u ON u.id = t.unit_id
                WHERE u.merged_at IS NOT NULL AND t.ts > u.merged_at
                ORDER BY u.base_key, u.generation, t.ts
                """)
            if rows.isEmpty { break }
            var progressed = false
            for row in rows {
                let turnID: String = row["turn_id"], ts: Int = row["ts"], unitID: String = row["unit_id"]
                guard let from = try WorkUnit.fetchOne(db, key: unitID) else { continue }
                let target = try nextGeneration(of: from, turnTs: ts, db: db)
                try db.execute(sql: "UPDATE obs_turn SET unit_id = ? WHERE id = ?", arguments: [target.id, turnID])
                touched.insert(from.id)
                touched.insert(target.id)
                moved += 1
                progressed = true
            }
            if !progressed { break }
        }
        // 양쪽을 DB 에서 다시 센다. 실제로 나눈 이번 한 번에 revision +1 — "평가 뒤 변경" 이 켜진다.
        for id in touched { try recount(id, db: db) }
        return moved
    }

    /// 원래 단위보다 높은 세대 중 이 턴을 받는 가장 낮은 세대. 없으면 같은 자리 · 같은 열쇠 형식으로 새로 만든다.
    private static func nextGeneration(of from: WorkUnit, turnTs: Int, db: Database) throws -> WorkUnit {
        let siblings = try WorkUnit.filter(Column("base_key") == from.baseKey).fetchAll(db)
        if case .existing(let u) = WorkUnitRules.chooseGeneration(siblings.filter { $0.generation > from.generation },
                                                                  turnTs: turnTs) {
            return u
        }
        // 위 필터가 비면 chooseGeneration 은 0 을 내놓는다 — 새 세대 번호는 같은 자리 전체의 최댓값에서 잇는다.
        let g = (siblings.map(\.generation).max() ?? from.generation) + 1
        // 머지 · PR 정보는 머지된 세대의 것이라 옮기지 않는다. 시각 · 카운터는 recount 가 채운다.
        let u = WorkUnit(unitKey: WorkUnitRules.unitKey(baseKey: from.baseKey, generation: g), baseKey: from.baseKey,
                         kind: from.kind, repoRoot: from.repoRoot, cwd: from.cwd, branch: from.branch, generation: g,
                         day: from.day, issueNo: from.issueNo, githubRepo: from.githubRepo, workspaceId: from.workspaceId,
                         firstTs: turnTs, lastTs: turnTs)
        try u.insert(db)
        return u
    }

    /// 수집이 쌓는 규칙과 같게 센다 — Edit 계열 툴은 서브에이전트 행(같은 turn_id)까지 포함한다.
    /// last_ts 는 턴 · 툴 시작 · 툴 결과 중 가장 늦은 것(답 줄의 시각은 저장하지 않아 다시 셀 수 없다).
    /// 턴이 하나도 남지 않은 단위는 시각을 그대로 둔다 — 셀 근거가 없다.
    private static func recount(_ unitID: String, db: Database) throws {
        let edits = ObsCollector.editTools.map { "'\($0)'" }.joined(separator: ",")
        try db.execute(sql: """
            UPDATE work_unit SET
              human_turns = (SELECT COUNT(*) FROM obs_turn WHERE unit_id = :id AND prompt_kind IN \(PromptKind.humanSQLList)),
              peer_turns = (SELECT COUNT(*) FROM obs_turn WHERE unit_id = :id AND prompt_kind = 'peer'),
              edit_count = (SELECT COUNT(*) FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id
                            WHERE t.unit_id = :id AND o.name IN (\(edits))),
              first_ts = COALESCE((SELECT MIN(ts) FROM obs_turn WHERE unit_id = :id), first_ts),
              last_ts = COALESCE((SELECT MAX(m) FROM (
                  SELECT ts AS m FROM obs_turn WHERE unit_id = :id
                  UNION ALL SELECT o.started_ts FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id WHERE t.unit_id = :id
                  UNION ALL SELECT o.result_ts FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id WHERE t.unit_id = :id
                )), last_ts),
              source_revision = source_revision + 1
            WHERE id = :id
            """, arguments: ["id": unitID])
    }
}
