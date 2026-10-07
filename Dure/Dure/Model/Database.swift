import Foundation
import GRDB

/// 부록 A4 스키마.
/// v1: workspace · repo (Step 2) — v2: agent · cc_session (Step 4)
/// — v3: read_cursor · token_usage · tool_use (Step 5)
/// — v4: workspace.default_agent_kind · repo.role (조율자 단계 1).
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
        m.registerMigration("v3_usage") { db in
            try db.create(table: "read_cursor") { t in
                t.primaryKey("path", .text)          // transcript_path
                t.column("byte_offset", .integer).notNull()
                t.column("line_no", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }

            try db.create(table: "token_usage") { t in
                // ⚠️ PK 가 (cc_session_id, message_id) 다. 부록 A4 의 line_no 가 아니다.
                //    한 응답이 여러 줄로 기록되고 각 줄이 usage 를 통째로 복사해 가지므로
                //    줄 단위로 쌓으면 약 2배가 된다 (A7-1). message_id 를 키로 잡으면
                //    둘째·셋째 줄이 같은 행을 덮어써서 중복이 구조적으로 불가능해진다.
                t.column("cc_session_id", .text).notNull()
                    .references("cc_session", onDelete: .cascade)
                t.column("message_id", .text).notNull()
                t.column("line_no", .integer).notNull()
                t.column("ts", .integer).notNull()
                t.column("input", .integer).notNull().defaults(to: 0)
                t.column("output", .integer).notNull().defaults(to: 0)
                t.column("cache_read", .integer).notNull().defaults(to: 0)
                t.column("cache_creation", .integer).notNull().defaults(to: 0)
                t.column("thinking", .integer).notNull().defaults(to: 0)
                t.column("service_tier", .text)
                t.column("model", .text)
                t.primaryKey(["cc_session_id", "message_id"])
            }

            try db.create(table: "tool_use") { t in
                // 한 줄에 tool_use 블록은 최대 1개다 (트랜스크립트 25개 실측, 2개 이상 0건).
                t.column("cc_session_id", .text).notNull()
                    .references("cc_session", onDelete: .cascade)
                t.column("line_no", .integer).notNull()
                t.column("ts", .integer).notNull()
                t.column("tool_name", .text).notNull()
                t.column("mcp_server", .text)
                t.column("skill_name", .text)
                t.primaryKey(["cc_session_id", "line_no"])
            }
            try db.create(index: "idx_tool_ts", on: "tool_use", columns: ["ts"])
        }
        m.registerMigration("v4_workspace_orchestrator") { db in
            // 기존 행에도 값이 있어야 하므로 NOT NULL + DEFAULT 로 넣는다.
            try db.alter(table: "workspace") { t in
                t.add(column: "default_agent_kind", .text).notNull().defaults(to: "claude")
            }
            // 역할은 안 적어도 되므로 nullable.
            try db.alter(table: "repo") { t in
                t.add(column: "role", .text)
            }
        }

        return m
    }
}
