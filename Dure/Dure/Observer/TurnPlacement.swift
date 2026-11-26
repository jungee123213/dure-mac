// Dure/Dure/Observer/TurnPlacement.swift
import Foundation
import GRDB

/// 레포 단위의 턴을 **마지막 활동 때의 자리**로 다시 놓는다(이슈 #60, D-48). 수집 끝 정합 단계에서 머지 세대 나누기보다 먼저 돈다.
///
/// 수집은 턴을 **시작할 때의** 브랜치 단위에 넣는다. 그런데 "이슈 올리고 고쳐줘" 한 턴이 브랜치를 새로 따고 구현까지 하면
/// 구현이 이전 브랜치 단위로 가서 PR 단위에서 빠진다(#56 · #58). 머지 뒤 main 으로 돌아가는 정리 턴은 머지 세대 뒤에
/// 빈 다음 세대를 만든다. 그래서 턴의 마지막 활동(본 세션 툴의 시작 · 결과 중 가장 늦은 시각) 때 HEAD 가 가리키던 브랜치(reflog)로 옮긴다.
/// reflog 가 모르면(만료 · 지워진 레포 · `HEAD`) 그대로 둔다. 툴이 없는 턴은 활동 시각이 없어 그대로다.
///
/// 지워진 레포는 수집이 cwd 를 루트로 써서 하위 폴더 세션이 따로 단위가 됐다(옛 데이터). 루트가 디스크에 없고
/// 이미 아는 루트 중 그것을 품는 것이 있으면 그 루트로 옮긴다 — 수집의 `resolve` 와 같은 규칙.
nonisolated enum TurnPlacement {

    /// 옮긴 턴 수. 옮길 게 없으면 아무것도 쓰지 않는다(멱등). 한 트랜잭션 안에서 부른다.
    @discardableResult
    static func reconcile(in db: Database, resolver: RepoResolving, config: CollectConfig,
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> Int {
        let known = try knownRoots(db)
        // 서브에이전트 툴(다른 파일)은 본 턴이 끝난 뒤에도 돌 수 있어 활동 시각에서 뺀다.
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id AS turn_id, t.ts AS ts, t.unit_id AS unit_id,
                   (SELECT MAX(MAX(o.started_ts, COALESCE(o.result_ts, o.started_ts))) FROM obs_tool o
                    WHERE o.turn_id = t.id AND o.transcript_path = t.transcript_path) AS last_act
            FROM obs_turn t JOIN work_unit u ON u.id = t.unit_id
            WHERE u.kind IN ('\(UnitKind.issueBranch.rawValue)', '\(UnitKind.defaultBranch.rawValue)')
              AND u.repo_root IS NOT NULL
            """)
        var units: [String: WorkUnit] = [:]
        var touched = Set<String>()
        var moved = 0
        for row in rows {
            let turnID: String = row["turn_id"], ts: Int = row["ts"], unitID: String = row["unit_id"]
            let lastAct: Int? = row["last_act"]
            guard let from = try units[unitID] ?? WorkUnit.fetchOne(db, key: unitID), let root = from.repoRoot else { continue }
            units[unitID] = from
            let newRoot = normalizedRoot(root, known: known, exists: exists)
            var branch = from.branch
            if let lastAct, let b = resolver.branch(atRoot: newRoot, ts: lastAct), b != "HEAD" { branch = b }
            guard newRoot != root || branch != from.branch else { continue }

            let info = resolver.info(forCwd: newRoot).flatMap { $0.root == newRoot ? $0 : nil }
                ?? RepoInfo(root: newRoot, defaultBranch: nil, githubRepo: from.githubRepo)
            let p = WorkUnitRules.place(cwd: newRoot, branch: branch, repo: info, ts: ts,
                                        timeZone: config.timeZone, workspacesRoot: config.workspacesRoot)
            guard p.baseKey != from.baseKey else { continue }
            let target = try ObsCollector.unit(for: p, ts: ts, githubRepo: info.githubRepo, db: db)
            try db.execute(sql: "UPDATE obs_turn SET unit_id = ? WHERE id = ?", arguments: [target.id, turnID])
            touched.insert(from.id)
            touched.insert(target.id)
            moved += 1
        }
        for id in touched { try GenerationSplit.recount(id, db: db) }
        return moved
    }

    /// 턴 · 평가 · PR 이 하나도 없는 단위를 지운다. 턴을 다른 단위로 옮기면 생긴다(재배치 · 세대 나누기 · v12).
    /// PR 이 적힌 단위는 남긴다 — 머지 기록이다.
    @discardableResult
    static func pruneEmpty(in db: Database) throws -> Int {
        try db.execute(sql: """
            DELETE FROM work_unit
            WHERE pr_number IS NULL
              AND NOT EXISTS (SELECT 1 FROM obs_turn t WHERE t.unit_id = work_unit.id)
              AND NOT EXISTS (SELECT 1 FROM evaluation_run r WHERE r.unit_id = work_unit.id)
            """)
        return db.changesCount
    }

    /// 두레가 아는 레포 루트 — 등록된 레포와 감시자 단위가 쓴 루트.
    static func knownRoots(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT path FROM repo UNION SELECT DISTINCT repo_root FROM work_unit WHERE repo_root IS NOT NULL
            """)
    }

    /// 디스크에 없는 경로는 아는 루트 중 그것을 품는 가장 짧은 것으로. 있거나 품는 루트가 없으면 그대로.
    /// 있는 경로는 건드리지 않는다 — 중첩 레포(서브모듈 · 워크트리)는 실제로 따로다.
    static func normalizedRoot(_ path: String, known: [String], exists: (String) -> Bool) -> String {
        guard !exists(path) else { return path }
        return known.filter { $0 != path && path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .min { $0.count < $1.count } ?? path
    }
}
