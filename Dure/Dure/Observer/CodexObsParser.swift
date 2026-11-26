// Dure/Dure/Observer/CodexObsParser.swift
import Foundation

/// Codex rollout(`~/.codex/sessions/.../rollout-*.jsonl`) 한 줄 → 감시자 이벤트. 수집기는 Claude 줄과 같은
/// `ObsParser.Event` 로 받는다. Claude 줄과 달리 세션 머리(`session_meta`)가 첫 줄에만 있어 상태를 들고 간다 —
/// 이어 읽기 때는 수집기가 `header(_:)` 로 첫 줄을 다시 읽어 `state` 를 채운다.
/// 줄 모양: `{"timestamp","ordinal","type","payload"}` (codex-cli 0.167.0 실측, `docs/spikes/2026-11-19-codex/k-stage5.md`).
/// 턴은 `item_completed UserMessage`, 답은 `item_completed AgentMessage`, 툴은 `item_completed` 툴 항목으로만 읽는다.
/// 깨진 줄은 `nil`.
nonisolated struct CodexObsParser {
    typealias Event = ObsParser.Event
    typealias Context = ObsParser.Context

    struct State: Equatable, Sendable {
        /// 이 파일의 스레드(`session_meta.id`).
        var sessionId: String?
        var cwd: String?
        /// 스레드 시작 때 브랜치. Context 에는 싣지 않는다(아래 `context`) — 수집기가 reflog 복원에 실패했을 때만 대신 쓴다.
        var gitBranch: String?
        var originator: String?
        var isSubagent = false
        var parentThreadId: String?
        var model: String?
        /// 루트 스레드(`session_meta.session_id`). 서브에이전트 파일은 부모 쪽 값이다.
        var rootSessionId: String?
        /// 가져온 Claude 세션(`history_mode: legacy`) — 파일 전체를 건너뛴다.
        var skip = false
        /// 지금 열린 **사용자** 턴(`UserMessage` 의 turn id).
        var turnId: String?
        /// 마지막 `task_started` 의 턴 · 트리거.
        var taskTurnId: String?
        var turnTrigger: String?
    }

    var state: State

    init(state: State = State()) { self.state = state }

    /// 평가에 쓰지 않는 것으로 **알고 있는** 줄. 하위 type 은 `event_msg.<type>` · `response_item.<type>` ·
    /// `item.<item type>` 으로 적는다. 여기 없는 것은 `unknownType` — 형식 변화를 드러낸다.
    static let knownTypes: Set<String> = [
        "world_state", "inter_agent_communication_metadata",
        "event_msg.token_count", "event_msg.thread_settings_applied",
        // 이벤트 모양 사용자 글 · 답은 가져온 Claude 세션(legacy)에만 있다 — 그 파일은 통째로 건너뛴다.
        "event_msg.user_message", "event_msg.agent_message",
        // 툴은 `item_completed` 로만 센다 — 같은 호출이 `custom_tool_call exec` · `function_call` 로도 남는다.
        // (`custom_tool_call_output` 은 패치 검증 실패만 본다 — `patchFailure`. `function_call_output` 의 같은 실패는
        // 못 잡는다 — 실측은 custom 모양만 봤다.)
        "response_item.message", "response_item.reasoning", "response_item.custom_tool_call",
        "response_item.custom_tool_call_output", "response_item.function_call", "response_item.function_call_output",
        "response_item.additional_tools", "response_item.configuration_update", "response_item.agent_message",
        // `Extension` 은 웹 검색(`kind: web.search`) — 지금은 툴로 세지 않는다. `HookPrompt` 부터 여덟은 스키마 `ThreadItem` 에만 있다.
        // `ContextCompaction` 은 `compacted` 줄과 늘 함께 생기는 같은 사건이라(실측) 압축은 `compacted` 줄로만 센다.
        "item.Reasoning", "item.Extension", "item.ImageView", "item.CollabAgentToolCall", "item.ContextCompaction",
        "item.HookPrompt", "item.Plan", "item.DynamicToolCall", "item.WebSearch", "item.ImageGeneration", "item.Sleep",
        "item.EnteredReviewMode", "item.ExitedReviewMode",
    ]

    /// 사람이 보낸 것으로 보는 턴 트리거. `queue` 는 `codex queue`(두레 배분), `user` 는 TUI 입력, nil 은 `turn/start`.
    /// 그 밖(`automation_heartbeat_scheduled` 등)은 자동으로 들어온 턴이다.
    static let humanTriggers: Set<String> = ["queue", "user", "composer"]

    /// `session_meta` 줄 하나로 상태를 채운다. 다른 줄 · 깨진 줄은 `nil`.
    static func header(_ data: Data) -> State? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any] else { return nil }
        return state(meta: payload)
    }

    mutating func parse(_ data: Data, lineNo: Int) -> [Event]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              let payload = root["payload"] as? [String: Any] else { return nil }
        if state.skip { return [.ignored] }
        switch type {
        case "session_meta":
            // 머리는 파일 첫 줄 하나뿐(실측). 혹시 더 오면 첫 것을 지킨다.
            guard state.sessionId == nil else { return [.ignored] }
            guard let s = Self.state(meta: payload) else { return nil }
            state = s
            return [.ignored]
        case "turn_context":
            if let cwd = payload["cwd"] as? String { state.cwd = cwd }
            if let model = payload["model"] as? String { state.model = model }
            return [.ignored]
        default:
            break
        }
        // 머리 전 줄은 깨진 줄이 아니다 — 어느 세션 것인지 모를 뿐.
        guard state.sessionId != nil, state.cwd != nil else { return [.ignored] }
        switch type {
        case "event_msg":
            return event(payload, root: root, lineNo: lineNo)
        case "token_usage_record":
            guard let ctx = context(root, lineNo: lineNo), let u = payload["usage"] as? [String: Any] else { return nil }
            let input = u["input_tokens"] as? Int ?? 0
            let cached = u["cached_input_tokens"] as? Int ?? 0
            let write = u["cache_write_input_tokens"] as? Int ?? 0
            // `input_tokens` 는 캐시 읽기 · 쓰기를 포함한다 — Claude 처럼 나눠 담는다(F6 `CodexTranscriptParser` 와 같은 정의).
            // 압축 턴의 사용량은 지금 열린 사용자 턴에 붙는다(Claude 도 압축 토큰은 그 세션 소비).
            let usage = ObsParser.Usage(input: max(0, input - cached - write), output: u["output_tokens"] as? Int ?? 0,
                                        cacheCreation: write, cacheRead: cached)
            return [.assistant(ctx, text: nil, messageId: payload["response_id"] as? String, model: state.model, usage: usage)]
        case "compacted":
            return [.compacted]
        case "response_item":
            let sub = payload["type"] as? String ?? ""
            if sub == "custom_tool_call_output", let failure = patchFailure(payload, root: root, lineNo: lineNo) {
                return failure
            }
            return [Self.known("response_item.\(sub)")]
        default:
            return [Self.known(type)]
        }
    }

    /// Codex Desktop 이 Claude 세션을 자기 스레드로 가져온 턴(이슈 #60). paginated 라 legacy 거르기에 안 걸린다.
    /// 같은 턴이 Claude 트랜스크립트에 이미 있으니 세면 두 번이 된다. 뒤에 직접 친 턴이 이어지는 파일이 있어 턴 단위로 거른다.
    static let importedTurnPrefix = "external-import-"

    private mutating func event(_ p: [String: Any], root: [String: Any], lineNo: Int) -> [Event]? {
        let sub = p["type"] as? String ?? ""
        // 가져온 턴의 사건은 상태(열린 턴 · 트리거)도 건드리지 않는다 — 직접 친 턴의 끝 · 중단 판정이 흐려지지 않게.
        if (p["turn_id"] as? String)?.hasPrefix(Self.importedTurnPrefix) == true { return [.ignored] }
        switch sub {
        case "task_started":
            let attribution = p["turn_attribution"] as? [String: Any]
            state.taskTurnId = p["turn_id"] as? String
            state.turnTrigger = attribution?["turn_trigger"] as? String
            return [.ignored]
        case "item_completed":
            guard let item = p["item"] as? [String: Any] else { return nil }
            return self.item(item, turn: p["turn_id"] as? String, timing: Self.timing(p), root: root, lineNo: lineNo)
        case "task_complete":
            guard endsUserTurn(p["turn_id"] as? String) else { return [.ignored] }
            return [Self.durationMs(p).map { .turnDuration(ms: $0) } ?? .ignored]
        case "turn_aborted":
            return [endsUserTurn(p["turn_id"] as? String) ? .interrupted : .ignored]
        default:
            return [Self.known("event_msg.\(sub)")]
        }
    }

    /// 끝난 턴이 지금 열린 사용자 턴인가. 압축 · `!명령` 은 사용자 글 없는 별도 턴이라, 그 끝(압축은 20ms)이
    /// 앞 사용자 턴의 시간 · 중단 표시를 덮지 않게 한다. 이어 읽기로 시작한 턴(`task_started` · `UserMessage` 를
    /// 이번에 못 본 턴)은 사용자 턴으로 본다 — 긴 턴 중간에 수집이 돌아도 시간을 잃지 않게.
    /// (이어 읽기 자리가 압축 턴 한가운데면 그 끝을 사용자 턴 끝으로 받는다 — 드물어 감수한다.)
    private func endsUserTurn(_ turn: String?) -> Bool {
        // 서브에이전트 턴의 끝은 부모 사용자 턴의 시간 · 중단이 아니다.
        if state.isSubagent { return false }
        guard let turn else { return true }
        if let open = state.turnId { return open == turn }
        return state.taskTurnId != turn
    }

    private mutating func item(_ item: [String: Any], turn: String?, timing: Timing, root: [String: Any],
                               lineNo: Int) -> [Event]? {
        let kind = item["type"] as? String ?? ""
        switch kind {
        case "UserMessage":
            // 서브에이전트 파일에는 사용자 글이 없다(과제는 `response_item agent_message`). 혹시 오면 사람 요청이 아니다.
            if state.isSubagent { return [.ignored] }
            guard let ctx = context(root, lineNo: lineNo) else { return nil }
            state.turnId = turn ?? state.taskTurnId
            let text = ObsParser.plain(item["content"])
            return [.turnStart(ctx, prompt: text, kind: promptKind(text), permissionMode: nil)]
        case "AgentMessage":
            guard let ctx = context(root, lineNo: lineNo) else { return nil }
            let text = ObsParser.plain(item["content"], textTypes: ["Text", "text"])
            return [.assistant(ctx, text: text.isEmpty ? nil : text, messageId: nil, model: state.model, usage: .init())]
        case "CommandExecution", "FileChange", "McpToolCall":
            // 사람이 TUI 에서 친 `!명령` 은 에이전트 툴이 아니다.
            if item["source"] as? String == "user_shell" { return [.ignored] }
            guard let ctx = context(root, lineNo: lineNo) else { return nil }
            return Self.tool(item, ctx: ctx, timing: timing)
        case "SubAgentActivity":
            // 서브에이전트 띄우기 하나에 `started` 하나(실측, id = 띄운 호출의 call_id) — 이것만 `Agent` 툴로 센다
            // (Claude `Agent` 와 같은 뜻). `completed` 와 협업 툴 항목(`CollabAgentToolCall` — `wait` 등)은 무시.
            guard item["kind"] as? String == "started" else { return [.ignored] }
            guard let ctx = context(root, lineNo: lineNo), let id = item["id"] as? String else { return nil }
            return [.toolUse(ctx, id: id, name: "Agent", target: item["agent_path"] as? String)]
        default:
            return [Self.known("item.\(kind)")]
        }
    }

    /// `[두레]` 로 시작하면 배분(큐로 온다), 자동 트리거면 알림, 그 밖은 Claude 와 같은 분류.
    private func promptKind(_ text: String) -> PromptKind {
        if text.drop(while: \.isWhitespace).hasPrefix("[두레]") { return .peer }
        if let trigger = state.turnTrigger, !Self.humanTriggers.contains(trigger) { return .notice }
        return ObsParser.classify(text) ?? .human
    }

    static let patchFailurePhrase = "apply_patch verification failed"

    /// 패치 검증이 실패하면 `FileChange` 항목이 아예 없다 — 실패는 툴 출력 글에만 남는다(실측).
    /// 직접 호출은 출력 전체가 그 문구로 시작하고, code-mode `exec` 는 출력이 `Script failed` 로 시작하고 그 문구로
    /// 시작하는 줄(`Script error:` 다음)이 있다. 성공한 명령의 출력이 문구를 담기만 한 것(코드 검색 등)은 실패가 아니다.
    /// 같은 호출의 `FileChange` 가 없으니 두 번 세지 않는다.
    private func patchFailure(_ p: [String: Any], root: [String: Any], lineNo: Int) -> [Event]? {
        let output = ObsParser.plain(p["output"], textTypes: ["input_text", "output_text", "text"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = Self.patchFailurePhrase
        let line: Substring?
        if output.hasPrefix(phrase) {
            line = output.split(separator: "\n").first
        } else if output.hasPrefix("Script failed") {
            line = output.split(separator: "\n").first { $0.drop(while: \.isWhitespace).hasPrefix(phrase) }
                .map { $0.drop(while: \.isWhitespace) }
        } else {
            line = nil
        }
        guard let line, let id = p["call_id"] as? String, let ctx = context(root, lineNo: lineNo) else { return nil }
        return [.toolUse(ctx, id: id, name: "Edit", target: nil),
                .toolResult(ts: ctx.ts, toolUseId: id, isError: true, errorHead: String(line.prefix(200)), denied: false)]
    }

    /// `item_completed` 의 항목 시작 · 끝(초). 줄 시각은 끝난 때라 시작과 끝이 같아진다 — 항목 시각이 있으면 그걸 쓴다
    /// (`Signals` 지연 판정). 실측 값은 epoch ms 다. 그보다 작은 값(형식이 다른 것)은 버린다.
    typealias Timing = (start: Int?, end: Int?)

    static func timing(_ p: [String: Any]) -> Timing {
        func seconds(_ key: String) -> Int? {
            guard let ms = p[key] as? Int, ms >= 1_000_000_000_000 else { return nil }
            return ms / 1000
        }
        return (seconds("started_at_ms"), seconds("completed_at_ms"))
    }

    /// 사람이 승인 창에서 거절한 툴(`declined`)의 errorHead. 출력 글이 아니라 고정 문구 — `UsageStats.isHumanRejection` 이
    /// Claude 의 거절 문구처럼 알아보고 툴 오류로 세지 않는다.
    static let declinedHead = "Declined by user in Codex approval"

    /// 툴 호출 항목 → 호출 + 결과. Claude 툴 이름에 맞춘다(셸 `Bash` · 파일 수정 `Edit` · MCP `mcp__<서버>__<툴>`).
    private static func tool(_ item: [String: Any], ctx: Context, timing: Timing) -> [Event]? {
        guard let id = item["id"] as? String else { return nil }
        let status = item["status"] as? String
        // `declined` 는 사람이 승인 창에서 거절한 것 — Claude 의 거부(`denied`)와 같다.
        let failed = status == "failed", declined = status == "declined"
        let name: String, target: String?, isError: Bool
        var errorText: String
        switch item["type"] as? String {
        case "CommandExecution":
            name = "Bash"
            target = commandLine(item["command"]).map { String($0.prefix(120)) }
            let exit = item["exit_code"] as? Int
            isError = failed || declined || (exit ?? 0) != 0
            errorText = item["aggregated_output"] as? String ?? ""
            // 출력 없는 실패는 Claude 의 `Exit code N` 과 같은 모양으로 — 대시보드가 빈 줄 대신 "종료 코드만" 으로 거른다.
            if let exit, exit != 0, errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorText = "Exit code \(exit)"
            }
        case "FileChange":
            // 한 항목이 여러 파일을 고칠 수 있다. 사전 순서는 JSON 에서 보존되지 않아 정렬해 첫 경로로 정한다.
            name = "Edit"
            target = (item["changes"] as? [String: Any])?.keys.sorted().first
            isError = failed || declined
            errorText = item["stderr"] as? String ?? ""
        default:
            guard let server = item["server"] as? String, let tool = item["tool"] as? String else { return nil }
            name = "mcp__\(server)__\(tool)"
            target = ObsParser.target(name: name, input: item["arguments"] as? [String: Any])
            let result = item["result"] as? [String: Any]
            isError = failed || declined || result?["isError"] as? Bool == true
            errorText = mcpError(item, result: result)
        }
        if declined { errorText = declinedHead }
        let head = isError ? ObsParser.firstLine(errorText, max: 200) : ""
        var started = ctx
        if let s = timing.start { started.ts = s }
        return [.toolUse(started, id: id, name: name, target: target),
                .toolResult(ts: timing.end ?? ctx.ts, toolUseId: id, isError: isError, errorHead: head.isEmpty ? nil : head,
                            denied: declined)]
    }

    static let shells: Set<String> = ["zsh", "bash", "sh"]

    /// `["/bin/zsh", "-lc", "git status"]` 처럼 셸로 감싼 명령은 마지막 원소만 — Claude `Bash` 의 target 과 같은 모양.
    /// 셸이 아닌 argv 는 공백으로 잇는다(`["git", "status"]` 가 `status` 가 되지 않게).
    static func commandLine(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let argv = value as? [String], !argv.isEmpty else { return nil }
        let program = argv[0].split(separator: "/").last.map(String.init) ?? argv[0]
        if argv.count == 3, shells.contains(program), ["-c", "-lc", "-ilc"].contains(argv[1]) { return argv[2] }
        return argv.joined(separator: " ")
    }

    private static func mcpError(_ item: [String: Any], result: [String: Any]?) -> String {
        let text = ObsParser.plain(result?["content"])
        if !text.isEmpty { return text }
        if let e = item["error"] as? String { return e }
        let meta = (result?["_meta"] as? [String: Any])?["error"] as? [String: Any]
        return (item["error"] as? [String: Any])?["message"] as? String ?? meta?["message"] as? String ?? ""
    }

    /// 턴 길이. 옛 판은 `duration_ms` 없이 시작 · 끝 시각(초)만 남긴다.
    static func durationMs(_ p: [String: Any]) -> Int? {
        if let ms = p["duration_ms"] as? Int { return ms }
        if let start = p["started_at"] as? Int, let end = p["completed_at"] as? Int, end >= start { return (end - start) * 1000 }
        return nil
    }

    /// 서브에이전트 rollout 인가 · 부모 thread(실측: `thread_source: "subagent"`, `parent_thread_id`,
    /// `source: {"subagent": {"thread_spawn": {parent_thread_id, …}}}` — `source` 는 문자열이 아닐 수 있다). 판정은 여기 한 곳.
    static func subagentMark(_ meta: [String: Any]) -> (isSubagent: Bool, parentThreadId: String?) {
        let spawn = ((meta["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
        let parent = meta["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
        let tagged = meta["thread_source"] as? String == "subagent"
            || (meta["source"] as? [String: Any])?["subagent"] != nil
        return (tagged || parent != nil, parent)
    }

    private static func state(meta p: [String: Any]) -> State? {
        guard let id = p["id"] as? String ?? p["session_id"] as? String else { return nil }
        let mark = subagentMark(p)
        var s = State(sessionId: id, cwd: p["cwd"] as? String,
                      gitBranch: (p["git"] as? [String: Any])?["branch"] as? String,
                      originator: p["originator"] as? String, isSubagent: mark.isSubagent,
                      parentThreadId: mark.parentThreadId, model: nil)
        s.rootSessionId = p["session_id"] as? String ?? id
        s.skip = p["history_mode"] as? String == "legacy"
        return s
    }

    private static func known(_ type: String) -> Event {
        knownTypes.contains(type) ? .ignored : .unknownType(type)
    }

    /// 서브에이전트 줄은 Claude 서브에이전트 줄처럼 루트 세션 id 를 갖고(`isSidechain`), 사건 id 는 자기 스레드로 짓는다.
    /// 브랜치는 nil — `session_meta.git.branch` 는 스레드 시작 때 값이라 세션 중 만든 브랜치를 모른다. 수집기의
    /// reflog 복원(D-40)이 턴 시각으로 정하고, 못 정하면 이 값(`state.gitBranch`)으로 메운다. 출처는 `originator` 로 가르지 못한다(서버에 처음 붙은 클라이언트 이름).
    private func context(_ root: [String: Any], lineNo: Int) -> Context? {
        guard let own = state.sessionId, let cwd = state.cwd,
              let tsString = root["timestamp"] as? String, let ts = ObsParser.epoch(tsString) else { return nil }
        return Context(sessionId: state.isSubagent ? state.rootSessionId ?? own : own, cwd: cwd, gitBranch: nil, ts: ts,
                       entrypoint: "codex", isSidechain: state.isSubagent, eventId: "\(own):\(lineNo)")
    }
}
