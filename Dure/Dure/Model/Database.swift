import Foundation
import GRDB

/// 부록 A4 스키마.
/// v1: workspace · repo (Step 2) — v2: agent · cc_session (Step 4).
/// read_cursor · token_usage · tool_use 는 Step 5 에서 얹는다.
enum AppDatabase {

    /// 부록 A5 — GRDB 는 `DatabaseQueue` 하나로 직렬화한다.
    static let queue: DatabaseQueue = {
        do { return try makeQueue() }
        catch { fatalError("DB 초기화 실패: \(error)") }
    }()

    static func makeQueue() throws -> DatabaseQueue {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory,
                             in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Dure", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let q = try DatabaseQueue(path: dir.appendingPathComponent("dure.sqlite").path)
        try migrator.migrate(q)
        return q
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_workspace_repo") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
            }
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("label", .text)
                // v5 — 터미널별 모델. claude --model 에 그대로 넘긴다. NULL 이면 기본값.
                t.column("model", .text)
            }
        }
        m.registerMigration("v2_agent_ccsession") { db in
            try db.create(table: "agent") { t in
                // 앱이 spawn 시 만든 UUID. 훅이 DURE_SESSION 으로 돌려준다 (ADR-14).
                t.primaryKey("dure_session", .text)
                t.column("repo_id", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("agent_kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("model", .text)
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
            }
            try db.create(index: "idx_agent_repo", on: "agent", columns: ["repo_id"])

            try db.create(table: "cc_session") { t in
                // ⚠️ PK 는 cc_session_id 다. dure_session 으로 잡으면 /clear 이후
                //    앞선 트랜스크립트의 토큰이 조용히 유실된다 (부록 A4).
                t.primaryKey("cc_session_id", .text)
                t.column("dure_session", .text).notNull()
                    .references("agent", onDelete: .cascade)
                t.column("transcript_path", .text).notNull()
                t.column("source", .text).notNull()
                t.column("model", .text)
                t.column("started_at", .integer).notNull()
            }
            try db.create(index: "idx_ccsession_agent", on: "cc_session", columns: ["dure_session"])
        }
        return m
    }
}
