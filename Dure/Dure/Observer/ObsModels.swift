// Dure/Dure/Observer/ObsModels.swift
import Foundation
import GRDB

/// 감시자(이슈 #23) 의 표. 스펙 v2 8절.
/// **전부 `nonisolated`** — 수집 · 평가가 백그라운드에서 돈다(`GitReader` 와 같은 이유).
/// 작업 단위(자라는 것)와 평가 실행(그 순간의 불변 기록)을 나눈다(D-36, 리뷰 P1-B).

nonisolated enum UnitKind: String, Codable, Sendable {
    case issueBranch = "issue_branch", defaultBranch = "default_branch", noGit = "no_git", orchestrator
}
nonisolated enum TurnOrigin: String, Codable, Sendable {
    case dureRepo = "dure_repo", dureOrchestrator = "dure_orchestrator", terminal
}
/// 사람이 친 것 · 다른 세션(두레 배분)이 넣은 것 · `claude -p`.
/// 턴을 연 입력의 종류. 이슈 #32 — `!` 셸 · 슬래시 명령 · 작업 알림도 사용자 줄로 기록되지만 사람의 요청은 아니다.
/// `command` 는 사용자 정의 · 플러그인 명령(`/pr-draft`), `builtin` 은 내장 관리 명령(`/clear`).
nonisolated enum PromptKind: String, Codable, Sendable, CaseIterable {
    case human, peer, sdk, shell, command, builtin, notice

    /// `human_turns` 에 세는가. 사용자 정의 명령은 사람이 일을 시킨 것이다.
    var countsAsHuman: Bool { self == .human || self == .command }

    /// SQL `IN` 목록 — 재계산이 카운터와 같은 규칙을 쓰게 여기서만 만든다.
    static let humanSQLList = "(" + allCases.filter(\.countsAsHuman).map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"
}
nonisolated enum RunStatus: String, Codable, Sendable { case queued, running, done, failed, interrupted, cancelled }
/// 하루 상한은 `auto` 만 센다 — 사람이 누른 것까지 막으면 버튼이 거짓말을 한다.
nonisolated enum RunTrigger: String, Codable, Sendable { case auto, manual }
nonisolated enum BacklogBucket: String, Codable, Sendable { case dure, habit }
nonisolated enum BacklogState: String, Codable, Sendable { case open, issued, resolved, reopened, dismissed }
nonisolated enum FindingFeedback: String, Codable, Sendable { case useful, falsePositive = "false_positive" }

nonisolated struct ObsCursor: Codable, FetchableRecord, PersistableRecord, Sendable {
    var path: String
    var byteOffset: Int
    var lineNo: Int
    /// 둘 다 같으면 파일을 열지 않는다(첫 수집이 수백 MB 다).
    var mtime: Int
    var size: Int
    /// 첫 줄의 `uuid`. 바뀌면 파일이 교체된 것 — 처음부터 다시 읽는다.
    var fingerprint: String?
    /// 최근 기준 형식 경고(리뷰 P1-I). 합이 2000 을 넘으면 반으로 줄여 옛 기록이 새 형식 변화를 가리지 않게 한다.
    var recentBad: Int = 0
    var recentTotal: Int = 0
    var unknownTypes: Int = 0

    static let databaseTableName = "obs_cursor"
    enum CodingKeys: String, CodingKey {
        case path, mtime, size, fingerprint
        case byteOffset = "byte_offset", lineNo = "line_no", recentBad = "recent_bad"
        case recentTotal = "recent_total", unknownTypes = "unknown_types"
    }
}

nonisolated struct WorkUnit: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    /// `WorkUnitRules.Placement.key(generation:)`. 열 조합 UNIQUE 를 쓰지 않는다 — SQLite 는 NULL 끼리 다르다고 본다.
    var unitKey: String
    /// 세대를 뺀 열쇠. 같은 자리의 세대들을 찾는다(경로에 `%` `_` 가 있어 LIKE 를 쓰지 않는다).
    var baseKey: String
    var kind: UnitKind
    var repoRoot: String?
    var cwd: String?
    var branch: String?
    var generation: Int = 0
    var day: String?
    var issueNo: Int?
    var githubRepo: String?
    var workspaceId: String?
    /// 상위 "작업"(서버 · 안드로이드 · iOS 를 한 목표로) 자리. 지금은 쓰지 않는다(D-36).
    var taskId: String?
    var prNumber: Int?
    var prUrl: String?
    var prHead: String?
    var mergedAt: Int?
    var firstTs: Int
    var lastTs: Int
    var humanTurns: Int = 0
    var peerTurns: Int = 0
    /// 파일을 고친 툴 호출 수. 사람 말이 없어도 일을 한 작업을 자격에 넣는다(리뷰 P1-C).
    var editCount: Int = 0
    /// 새 턴 · 툴 · 사용량이 붙을 때마다 오른다. 평가는 이 값의 스냅숏이다 — 끝났을 때 더 크면 "평가 뒤 변경 있음".
    var sourceRevision: Int = 0
    var linesChanged: Int?

    static let databaseTableName = "work_unit"
    enum CodingKeys: String, CodingKey {
        case id, kind, cwd, branch, generation, day
        case unitKey = "unit_key", baseKey = "base_key", repoRoot = "repo_root", issueNo = "issue_no"
        case githubRepo = "github_repo", workspaceId = "workspace_id", taskId = "task_id"
        case prNumber = "pr_number", prUrl = "pr_url", prHead = "pr_head", mergedAt = "merged_at"
        case firstTs = "first_ts", lastTs = "last_ts", humanTurns = "human_turns", peerTurns = "peer_turns"
        case editCount = "edit_count", sourceRevision = "source_revision", linesChanged = "lines_changed"
    }

    /// 사람 턴 + 배분으로 받은 턴. 자동 평가 자격과 토큰 정규화의 분모.
    var activity: Int { humanTurns + peerTurns }

    var title: String {
        let place = ((repoRoot ?? cwd ?? "?") as NSString).lastPathComponent
        var parts = [place]
        if let issueNo { parts.append("#\(issueNo)") } else if let branch { parts.append(branch) }
        if let day { parts.append(day) }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct ObsTurn: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    var unitId: String
    /// 프롬프트 줄의 `uuid`(없으면 `경로:줄`). 근거의 주소이자 중복 방지 열쇠 — 파일이 다시 쓰여도 같은 사건은 같은 ID.
    var eventId: String
    var ccSessionId: String
    var transcriptPath: String
    var lineNo: Int
    var origin: TurnOrigin
    var promptKind: PromptKind
    var entrypoint: String?
    var ts: Int
    var prompt: String
    var permissionMode: String?
    var durationMs: Int?
    var answerTail: String?
    var interrupted: Bool = false
    var compacted: Bool = false
    var sidechainTools: Int = 0
    var tokensInput: Int = 0
    var tokensOutput: Int = 0
    var tokensCacheCreation: Int = 0
    var tokensCacheRead: Int = 0
    var sidechainTokens: Int = 0
    var model: String?
    /// 턴을 돌린 CLI(v11). 기존 행은 Claude.
    var agentKind: AgentKind = .claude

    static let databaseTableName = "obs_turn"
    enum CodingKeys: String, CodingKey {
        case id, origin, entrypoint, ts, prompt, interrupted, compacted, model
        case unitId = "unit_id", eventId = "event_id", ccSessionId = "cc_session_id", transcriptPath = "transcript_path"
        case lineNo = "line_no", promptKind = "prompt_kind", permissionMode = "permission_mode"
        case durationMs = "duration_ms", answerTail = "answer_tail", sidechainTools = "sidechain_tools"
        case tokensInput = "tokens_input", tokensOutput = "tokens_output"
        case tokensCacheCreation = "tokens_cache_creation", tokensCacheRead = "tokens_cache_read"
        case sidechainTokens = "sidechain_tokens", agentKind = "agent_kind"
    }

    /// 청구 기준(F6 `headline` 과 같은 정의 — 캐시 읽기 제외). 서브에이전트는 따로.
    var tokensHeadline: Int { tokensInput + tokensCacheCreation + tokensOutput }
}

/// 토큰 원장. 한 응답(message id)이 여러 줄 · 비연속으로 기록돼도 한 번만 센다(D-9 와 같은 원리, 리뷰 P1-I).
nonisolated struct ObsUsage: Codable, FetchableRecord, PersistableRecord, Sendable {
    var ccSessionId: String
    var messageId: String
    var turnId: String
    var sidechain: Bool

    static let databaseTableName = "obs_usage"
    enum CodingKeys: String, CodingKey {
        case sidechain
        case ccSessionId = "cc_session_id", messageId = "message_id", turnId = "turn_id"
    }
}

nonisolated struct ObsTool: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    var turnId: String
    var transcriptPath: String
    var toolUseId: String
    var name: String
    var target: String?
    var startedTs: Int
    var resultTs: Int?
    var isError: Bool = false
    var errorHead: String?
    var denied: Bool = false

    static let databaseTableName = "obs_tool"
    enum CodingKeys: String, CodingKey {
        case id, name, target, denied
        case turnId = "turn_id", transcriptPath = "transcript_path", toolUseId = "tool_use_id"
        case startedTs = "started_ts", resultTs = "result_ts", isError = "is_error", errorHead = "error_head"
    }
}

/// 두레 페인의 실제 승인 프롬프트(`Notification(permission_prompt)` 훅). 다이제스트가 시각으로 턴에 귀속한다.
nonisolated struct ObsPermission: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    var ccSessionId: String
    var ts: Int

    static let databaseTableName = "obs_permission"
    enum CodingKeys: String, CodingKey {
        case id, ts
        case ccSessionId = "cc_session_id"
    }
}

/// 앱이 `--session-id` 로 띄운 감시자 세션(평가 · 묻기). 수집에서 뺀다 — 경로 제외만으로는 cwd 가 레포인 세션을 못 거른다.
nonisolated struct ObserverSession: Codable, FetchableRecord, PersistableRecord, Sendable {
    var sessionId: String
    var kind: String
    var createdAt: Int

    static let databaseTableName = "observer_session"
    enum CodingKeys: String, CodingKey {
        case kind
        case sessionId = "session_id", createdAt = "created_at"
    }
}

nonisolated struct EvaluationRun: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    var unitId: String
    var trigger: RunTrigger
    var status: RunStatus
    /// 평가한 스냅숏. 단위의 현재 값이 더 크면 "평가 뒤 변경 있음".
    var sourceRevision: Int?
    var createdAt: Int
    var startedAt: Int?
    var finishedAt: Int?
    /// `total_cost_usd`. 구독이면 실제 청구가 아니라 "API 상당 비용" 이다.
    var costUsd: Double?
    var failure: String?
    var summary: String?
    var notes: String?
    var accepted: Int = 0
    var rejected: Int = 0
    var promptVersion: Int = 0
    var referenceStamp: String?
    var digestChars: Int?
    var sessionId: String?

    static let databaseTableName = "evaluation_run"
    enum CodingKeys: String, CodingKey {
        case id, trigger, status, failure, summary, notes, accepted, rejected
        case unitId = "unit_id", sourceRevision = "source_revision", createdAt = "created_at"
        case startedAt = "started_at", finishedAt = "finished_at", costUsd = "cost_usd"
        case promptVersion = "prompt_version", referenceStamp = "reference_stamp", digestChars = "digest_chars"
        case sessionId = "session_id"
    }
}

nonisolated struct BacklogItem: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    /// 평가자가 고른 slug. 같은 문제면 같은 key — 병합 동작은 결정론이지만 "같은 문제인가" 판단은 LLM 이다(리뷰 P1-F).
    var key: String
    var bucket: BacklogBucket
    var grp: String
    var kind: String
    var title: String
    var detail: String
    var suggestion: String?
    var applyText: String?
    var state: BacklogState
    var linkedIssue: String?
    /// 해결 표시 시각. 이 뒤에 관찰된 근거만 재발이다.
    var resolvedAt: Int?
    /// 아래 숫자는 `BacklogStore.recount` 가 finding 에서 다시 센 값이다. 직접 더하지 않는다.
    var observedCount: Int = 0
    var unitCount: Int = 0
    var maxSeverity: Int = 0
    var firstSeen: Int?
    var lastSeen: Int?
    var usefulCount: Int = 0
    var falsePositiveCount: Int = 0

    var id: String { key }
    static let databaseTableName = "backlog_item"
    enum CodingKeys: String, CodingKey {
        case key, bucket, grp, kind, title, detail, suggestion, state
        case applyText = "apply_text", linkedIssue = "linked_issue", resolvedAt = "resolved_at"
        case observedCount = "observed_count", unitCount = "unit_count", maxSeverity = "max_severity"
        case firstSeen = "first_seen", lastSeen = "last_seen"
        case usefulCount = "useful_count", falsePositiveCount = "false_positive_count"
    }
}

/// 실행에 고정된 지적(불변). 다시 평가하면 새 실행의 지적이 생기고 옛 것은 이력으로 남는다.
nonisolated struct Finding: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    var id: String = UUID().uuidString
    var runId: String
    var unitId: String
    var backlogKey: String
    var grp: String
    var kind: String
    var title: String
    var detail: String
    var suggestion: String?
    var applyText: String?
    /// 검증을 통과한 근거 `[{eventId, sessionId, turn, quote, ts}]` JSON.
    var evidence: String
    /// 근거 턴 시각의 최댓값 — 평가 시각이 아니다(옛 작업 재평가를 오늘 일로 세지 않는다).
    var observedAt: Int
    var severity: Int
    var confidence: String
    var createdAt: Int
    var feedback: FindingFeedback?
    var feedbackAt: Int?

    static let databaseTableName = "finding"
    enum CodingKeys: String, CodingKey {
        case id, grp, kind, title, detail, suggestion, evidence, severity, confidence, feedback
        case runId = "run_id", unitId = "unit_id", backlogKey = "backlog_key", applyText = "apply_text"
        case observedAt = "observed_at", createdAt = "created_at", feedbackAt = "feedback_at"
    }
}
