import Foundation
import GRDB

/// 부록 A4 스키마.
/// v1: workspace · repo (Step 2) — v2: agent · cc_session (Step 4)
/// — v3: read_cursor · token_usage · tool_use (Step 5)
/// — v4: workspace.default_agent_kind · repo.role (조율자 단계 1)
/// — v5: agent.workspace_id · agent.repo_id nullable (조율자 단계 3).
/// v6 (단계 4): dispatch · relay — 배분 큐이자 이력.
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

        m.registerMigration("v5_agent_workspace") { db in
            // 이슈 #16 — 조율자는 레포가 없다. SQLite 는 NOT NULL 을 풀 수 없어 테이블을 다시 만든다.
            // 순서(새 테이블 → 복사 → 옛 테이블 drop → rename)는 SQLite 공식 절차다.
            // GRDB 기본(foreignKeyChecks: .deferred)이 이 사이 외래키를 끄고 끝에서 무결성을 검사한다.
            try db.create(table: "agent_v5") { t in
                t.primaryKey("dure_session", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("repo_id", .text)
                    .references("repo", onDelete: .cascade)
                t.column("agent_kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("model", .text)
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
            }
            // JOIN 이라 레포가 이미 없는 행(원래 연쇄 삭제됐어야 할 고아)은 따라오지 않는다.
            try db.execute(sql: """
                INSERT INTO agent_v5 (dure_session, workspace_id, repo_id, agent_kind,
                                      state, model, started_at, ended_at)
                SELECT a.dure_session, r.workspace_id, a.repo_id, a.agent_kind,
                       a.state, a.model, a.started_at, a.ended_at
                FROM agent a JOIN repo r ON r.id = a.repo_id
                """)
            try db.drop(table: "agent")
            try db.rename(table: "agent_v5", to: "agent")
            try db.create(index: "idx_agent_repo", on: "agent", columns: ["repo_id"])
            try db.create(index: "idx_agent_workspace", on: "agent", columns: ["workspace_id"])
        }

        m.registerMigration("v6_dispatch_relay") { db in
            // 단계 4 — 배분 기록. 큐 상태도 여기 산다(앱을 껐다 켜도 큐가 남아야 한다).
            try db.create(table: "dispatch") { t in
                t.primaryKey("id", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("repo_id", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("title", .text)
                t.column("instruction", .text).notNull()
                t.column("state", .text).notNull()
                t.column("tool_use_id", .text)
                t.column("delivered_session", .text)
                t.column("result", .text)
                t.column("failure", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("delivered_at", .integer)
                t.column("done_at", .integer)
                t.uniqueKey(["workspace_id", "seq"])
            }
            try db.create(index: "idx_dispatch_repo_state", on: "dispatch", columns: ["repo_id", "state"])
            // 조율자행 메시지. 배분·레포가 지워져도 "그런 보고가 있었다" 는 남긴다(SET NULL).
            try db.create(table: "relay") { t in
                t.primaryKey("id", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("dispatch_id", .text)
                    .references("dispatch", onDelete: .setNull)
                t.column("repo_id", .text)
                    .references("repo", onDelete: .setNull)
                t.column("kind", .text).notNull()
                t.column("body", .text).notNull()
                t.column("state", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("delivered_at", .integer)
            }
            try db.create(index: "idx_relay_workspace_state", on: "relay", columns: ["workspace_id", "state"])
        }

        return m
    }
}
