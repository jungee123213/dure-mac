import Foundation
import GRDB

/// 부록 A4 스키마.
/// v1: workspace · repo (Step 2) — v2: agent · cc_session (Step 4)
/// — v3: read_cursor · token_usage · tool_use (Step 5)
/// — v4: workspace.default_agent_kind · repo.role (조율자 단계 1)
/// — v5: agent.workspace_id · agent.repo_id nullable (조율자 단계 3).
/// v6 (단계 4): dispatch · relay — 배분 큐이자 이력.
/// v7 (이슈 #23): 감시자 — 작업 단위 · 턴 · 원장 · 툴 · 평가 실행 · 백로그 · 지적.
enum AppDatabase {

    /// 부록 A5 — GRDB 는 `DatabaseQueue` 하나로 직렬화한다.
    static let queue: DatabaseQueue = {
        do { return try makeQueue() }
        catch { fatalError("DB 초기화 실패: \(error)") }
    }()

    enum OpenError: Error, Equatable { case testHost }

    /// 테스트 호스트에서는 열지 않는다(이슈 #29) — 피처 브랜치의 테스트가 머지 전 스키마를 실제 DB 에 올리면 안 된다.
    /// 테스트는 `migrator` 로 메모리 DB 를 만든다. 여기 오면 앱 본체가 테스트 중에 시작됐다는 뜻이라 크게 실패한다.
    static func makeQueue(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DatabaseQueue {
        guard !TestHost.isActive(environment) else { throw OpenError.testHost }
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

        m.registerMigration("v7_observer") { db in
            // 감시자. 원본 jsonl 은 Claude Code 가 지운다(cleanupPeriodDays 기본 30일) — 평가에 쓸 사실을 여기 떠 둔다.
            try db.create(table: "obs_cursor") { t in
                t.primaryKey("path", .text)
                t.column("byte_offset", .integer).notNull()
                t.column("line_no", .integer).notNull()
                t.column("mtime", .integer).notNull()
                t.column("size", .integer).notNull()
                t.column("fingerprint", .text)
                t.column("recent_bad", .integer).notNull().defaults(to: 0)
                t.column("recent_total", .integer).notNull().defaults(to: 0)
                t.column("unknown_types", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "work_unit") { t in
                t.primaryKey("id", .text)
                t.column("unit_key", .text).notNull().unique()
                t.column("base_key", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("repo_root", .text)
                t.column("cwd", .text)
                t.column("branch", .text)
                t.column("generation", .integer).notNull().defaults(to: 0)
                t.column("day", .text)
                t.column("issue_no", .integer)
                t.column("github_repo", .text)
                // 감시 기록은 워크스페이스가 아니라 사람의 것 — 워크스페이스를 지워도 단위는 남는다.
                t.column("workspace_id", .text).references("workspace", onDelete: .setNull)
                t.column("task_id", .text)
                t.column("pr_number", .integer)
                t.column("pr_url", .text)
                t.column("pr_head", .text)
                t.column("merged_at", .integer)
                t.column("first_ts", .integer).notNull()
                t.column("last_ts", .integer).notNull()
                t.column("human_turns", .integer).notNull().defaults(to: 0)
                t.column("peer_turns", .integer).notNull().defaults(to: 0)
                t.column("edit_count", .integer).notNull().defaults(to: 0)
                t.column("source_revision", .integer).notNull().defaults(to: 0)
                t.column("lines_changed", .integer)
            }
            try db.create(index: "idx_work_unit_base", on: "work_unit", columns: ["base_key"])
            try db.create(table: "obs_turn") { t in
                t.primaryKey("id", .text)
                t.column("unit_id", .text).notNull().references("work_unit", onDelete: .cascade)
                t.column("event_id", .text).notNull().unique()
                t.column("cc_session_id", .text).notNull()
                t.column("transcript_path", .text).notNull()
                t.column("line_no", .integer).notNull()
                t.column("origin", .text).notNull()
                t.column("prompt_kind", .text).notNull()
                t.column("entrypoint", .text)
                t.column("ts", .integer).notNull()
                t.column("prompt", .text).notNull()
                t.column("permission_mode", .text)
                t.column("duration_ms", .integer)
                t.column("answer_tail", .text)
                t.column("interrupted", .boolean).notNull().defaults(to: false)
                t.column("compacted", .boolean).notNull().defaults(to: false)
                t.column("sidechain_tools", .integer).notNull().defaults(to: 0)
                t.column("tokens_input", .integer).notNull().defaults(to: 0)
                t.column("tokens_output", .integer).notNull().defaults(to: 0)
                t.column("tokens_cache_creation", .integer).notNull().defaults(to: 0)
                t.column("tokens_cache_read", .integer).notNull().defaults(to: 0)
                t.column("sidechain_tokens", .integer).notNull().defaults(to: 0)
                t.column("model", .text)
            }
            try db.create(index: "idx_obs_turn_unit", on: "obs_turn", columns: ["unit_id"])
            try db.create(index: "idx_obs_turn_session_ts", on: "obs_turn", columns: ["cc_session_id", "ts"])
            try db.create(index: "idx_obs_turn_path_line", on: "obs_turn", columns: ["transcript_path", "line_no"])
            try db.create(table: "obs_usage") { t in
                t.column("cc_session_id", .text).notNull()
                t.column("message_id", .text).notNull()
                t.column("turn_id", .text).notNull().references("obs_turn", onDelete: .cascade)
                t.column("sidechain", .boolean).notNull()
                t.primaryKey(["cc_session_id", "message_id"])
            }
            try db.create(table: "obs_tool") { t in
                t.primaryKey("id", .text)
                t.column("turn_id", .text).notNull().references("obs_turn", onDelete: .cascade)
                t.column("transcript_path", .text).notNull()
                t.column("tool_use_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("target", .text)
                t.column("started_ts", .integer).notNull()
                t.column("result_ts", .integer)
                t.column("is_error", .boolean).notNull().defaults(to: false)
                t.column("error_head", .text)
                t.column("denied", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["transcript_path", "tool_use_id"])
            }
            try db.create(index: "idx_obs_tool_turn", on: "obs_tool", columns: ["turn_id"])
            try db.create(table: "obs_permission") { t in
                t.primaryKey("id", .text)
                t.column("cc_session_id", .text).notNull()
                t.column("ts", .integer).notNull()
            }
            try db.create(index: "idx_obs_permission_session", on: "obs_permission", columns: ["cc_session_id"])
            try db.create(table: "observer_session") { t in
                t.primaryKey("session_id", .text)
                t.column("kind", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "evaluation_run") { t in
                t.primaryKey("id", .text)
                t.column("unit_id", .text).notNull().references("work_unit", onDelete: .cascade)
                t.column("trigger", .text).notNull()
                t.column("status", .text).notNull()
                t.column("source_revision", .integer)
                t.column("created_at", .integer).notNull()
                t.column("started_at", .integer)
                t.column("finished_at", .integer)
                t.column("cost_usd", .double)
                t.column("failure", .text)
                t.column("summary", .text)
                t.column("notes", .text)
                t.column("accepted", .integer).notNull().defaults(to: 0)
                t.column("rejected", .integer).notNull().defaults(to: 0)
                t.column("prompt_version", .integer).notNull().defaults(to: 0)
                t.column("reference_stamp", .text)
                t.column("digest_chars", .integer)
                t.column("session_id", .text)
            }
            try db.create(index: "idx_run_unit", on: "evaluation_run", columns: ["unit_id"])
            try db.create(index: "idx_run_status", on: "evaluation_run", columns: ["status"])
            try db.create(table: "backlog_item") { t in
                t.primaryKey("key", .text)
                t.column("bucket", .text).notNull()
                t.column("grp", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("suggestion", .text)
                t.column("apply_text", .text)
                t.column("state", .text).notNull()
                t.column("linked_issue", .text)
                t.column("resolved_at", .integer)
                t.column("observed_count", .integer).notNull().defaults(to: 0)
                t.column("unit_count", .integer).notNull().defaults(to: 0)
                t.column("max_severity", .integer).notNull().defaults(to: 0)
                t.column("first_seen", .integer)
                t.column("last_seen", .integer)
                t.column("useful_count", .integer).notNull().defaults(to: 0)
                t.column("false_positive_count", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "finding") { t in
                t.primaryKey("id", .text)
                t.column("run_id", .text).notNull().references("evaluation_run", onDelete: .cascade)
                t.column("unit_id", .text).notNull().references("work_unit", onDelete: .cascade)
                t.column("backlog_key", .text).notNull().references("backlog_item", onDelete: .cascade)
                t.column("grp", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("suggestion", .text)
                t.column("apply_text", .text)
                t.column("evidence", .text).notNull()
                t.column("observed_at", .integer).notNull()
                t.column("severity", .integer).notNull()
                t.column("confidence", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("feedback", .text)
                t.column("feedback_at", .integer)
            }
            try db.create(index: "idx_finding_run", on: "finding", columns: ["run_id"])
            try db.create(index: "idx_finding_unit", on: "finding", columns: ["unit_id"])
            try db.create(index: "idx_finding_key", on: "finding", columns: ["backlog_key"])
        }

        m.registerMigration("v8_dispatch_git") { db in
            // 이슈 기반 배분 — 전부 NULL 허용(옛 행은 git 을 안 쓰는 배분).
            try db.alter(table: "dispatch") { t in
                t.add(column: "git_mode", .text)
                t.add(column: "issue_title", .text)
                t.add(column: "issue_body", .text)
                t.add(column: "git_scope", .text)
                t.add(column: "branch_hint", .text)
                t.add(column: "base_branch", .text)
                t.add(column: "issue_number", .integer)
                t.add(column: "branch", .text)
                t.add(column: "pr_number", .integer)
            }
        }

        m.registerMigration("v9_answer") { db in
            try db.create(table: "answer") { t in
                t.primaryKey("id", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("repo_id", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("dispatch_id", .text)
                    .references("dispatch", onDelete: .setNull)
                t.column("question_id", .text)
                    .references("relay", onDelete: .setNull)
                t.column("body", .text).notNull()
                t.column("state", .text).notNull()
                t.column("failure", .text)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("delivered_at", .integer)
            }
            try db.create(index: "idx_answer_repo_state", on: "answer", columns: ["repo_id", "state"])
        }

        // v10 — Codex 사용 한도의 마지막 값. 창마다 한 행(`(kind, window)`), 쌓지 않는다.
        m.registerMigration("v10_rate_limit") { db in
            try db.create(table: "rate_limit") { t in
                t.column("kind", .text).notNull()
                t.column("window", .text).notNull()
                t.column("used_percent", .integer).notNull()
                t.column("window_minutes", .integer)
                t.column("resets_at", .integer)
                t.column("plan_type", .text)
                t.column("reached_type", .text)
                t.column("seen_at", .integer).notNull()
                t.primaryKey(["kind", "window"])
            }
        }

        // v11 — 감시자 턴을 돌린 CLI(Codex 지원 5단계). 이미 쌓인 턴은 전부 Claude 트랜스크립트에서 왔다.
        m.registerMigration("v11_obs_agent_kind") { db in
            try db.alter(table: "obs_turn") { t in
                t.add(column: "agent_kind", .text).notNull().defaults(to: "claude")
            }
        }

        // v12 — 감시자 데이터 정확도(이슈 #60, D-48). 원본이 지워진 턴이 40% 라 다시 수집하지 않고 DB 에서 고친다.
        // 규칙은 그때 값으로 SQL 에 박는다 — 앱 코드(재계산 · 정리)가 나중에 바뀌어도 이 마이그레이션의 뜻은 그대로다.
        m.registerMigration("v12_observer_accuracy") { db in
            // ① 서브에이전트 결과 줄은 배분이 아니라 알림 턴.
            let handback = "prompt_kind = 'peer' AND prompt LIKE '[Subagent hand-back]%'"
            // ② Codex Desktop 이 가져온 Claude 세션 사본 — 이미 쌓인 행은 파일 줄로 되짚을 수 없어(가져오기가 파일 앞을 다시 쓴다)
            // 모양으로 고른다: 토큰 0 · 툴 0 · 그보다 앞선 Claude 턴과 프롬프트가 같다. 파일 대조 실측 66개 오탐 0, 7개 놓침.
            let imported = """
                agent_kind = 'codex'
                AND tokens_input + tokens_output + tokens_cache_creation + tokens_cache_read = 0
                AND NOT EXISTS (SELECT 1 FROM obs_tool o WHERE o.turn_id = obs_turn.id)
                AND EXISTS (SELECT 1 FROM obs_turn k WHERE k.agent_kind = 'claude' AND k.prompt = obs_turn.prompt
                            AND k.ts <= obs_turn.ts)
                """
            let changed = Set(try String.fetchAll(db, sql: "SELECT DISTINCT unit_id FROM obs_turn WHERE \(handback)")
                              + String.fetchAll(db, sql: "SELECT DISTINCT unit_id FROM obs_turn WHERE \(imported)"))
            try db.execute(sql: "UPDATE obs_turn SET prompt_kind = 'notice' WHERE \(handback)")
            try db.execute(sql: "DELETE FROM obs_turn WHERE \(imported)")   // obs_tool · obs_usage 는 FK 로 따라간다
            // 바뀐 단위만 다시 센다 — 안 바뀐 단위에 "평가 뒤 변경" 이 켜지지 않게. 시각은 남은 턴이 없으면 그대로.
            for id in changed {
                try db.execute(sql: """
                    UPDATE work_unit SET
                      human_turns = (SELECT COUNT(*) FROM obs_turn WHERE unit_id = :id AND prompt_kind IN ('human', 'command')),
                      peer_turns = (SELECT COUNT(*) FROM obs_turn WHERE unit_id = :id AND prompt_kind = 'peer'),
                      edit_count = (SELECT COUNT(*) FROM obs_tool o JOIN obs_turn t ON t.id = o.turn_id
                                    WHERE t.unit_id = :id AND o.name IN ('Edit', 'Write', 'MultiEdit', 'NotebookEdit')),
                      first_ts = COALESCE((SELECT MIN(ts) FROM obs_turn WHERE unit_id = :id), first_ts),
                      source_revision = source_revision + 1
                    WHERE id = :id
                    """, arguments: ["id": id])
            }
            // 턴이 모두 사라진 단위 — 평가 · PR 이 없으면 지운다(PR 은 머지 기록, 평가는 그때 다이제스트가 근거).
            try db.execute(sql: """
                DELETE FROM work_unit
                WHERE pr_number IS NULL
                  AND NOT EXISTS (SELECT 1 FROM obs_turn t WHERE t.unit_id = work_unit.id)
                  AND NOT EXISTS (SELECT 1 FROM evaluation_run r WHERE r.unit_id = work_unit.id)
                """)
        }

        return m
    }
}
