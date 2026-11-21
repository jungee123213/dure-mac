// Dure/DureTests/CodexObsParserTests.swift
import Foundation
import Testing
@testable import Dure

/// Codex rollout 줄(codex-cli 0.167.0 · 0.169 실측 모양, 내용은 지어낸 것).
enum CFx {
    static let ts = "2026-11-20T01:00:00.000Z"
    static let epoch = 1_795_136_400

    static func line(_ type: String, _ payload: [String: Any], ts: String = ts) -> String {
        Fx.json(["timestamp": ts, "ordinal": 1, "type": type, "payload": payload])
    }

    static func meta(session: String = "th-1", root: String? = nil, cwd: String = "/r/ios", branch: String? = "feat/#54/x",
                     originator: String? = "dure", source: Any = "vscode", threadSource: String? = "user",
                     historyMode: String = "paginated", extra: [String: Any] = [:]) -> String {
        var p: [String: Any] = ["id": session, "session_id": root ?? session, "timestamp": ts, "cwd": cwd,
                                "cli_version": "0.167.0", "source": source, "model_provider": "openai",
                                "history_mode": historyMode, "base_instructions": ["text": "…"], "dynamic_tools": []]
        if let originator { p["originator"] = originator }
        if let threadSource { p["thread_source"] = threadSource }
        if let branch { p["git"] = ["commit_hash": "abc", "branch": branch, "repository_url": "git@x:y.git"] }
        for (k, v) in extra { p[k] = v }
        return line("session_meta", p)
    }

    static func turnContext(cwd: String = "/r/ios", model: String = "gpt-5.5-codex", turn: String = "t1") -> String {
        line("turn_context", ["turn_id": turn, "cwd": cwd, "model": model, "approval_policy": "on-request",
                              "sandbox_policy": ["type": "workspace-write"]])
    }

    static func event(_ sub: String, _ fields: [String: Any] = [:], ts: String = ts) -> String {
        var p = fields
        p["type"] = sub
        return line("event_msg", p, ts: ts)
    }

    static func taskStarted(turn: String = "t1", trigger: String? = "user", attribution: Bool = true) -> String {
        var a: [String: Any] = ["turn_id": turn, "parent_turn_id": NSNull(), "root_turn_id": turn]
        a["turn_trigger"] = trigger ?? NSNull()
        var f: [String: Any] = ["turn_id": turn, "started_at": 1_795_136_400]
        if attribution { f["turn_attribution"] = a }
        return event("task_started", f)
    }

    /// 가져온 Claude 세션(legacy)에만 있는 이벤트 모양 사용자 글.
    static func userMessageEvent(_ text: String) -> String {
        event("user_message", ["message": text, "local_images": [], "text_elements": []])
    }

    static func taskComplete(turn: String = "t1", ms: Int?) -> String {
        var f: [String: Any] = ["turn_id": turn, "last_agent_message": "x", "started_at": 10]
        if let ms { f["duration_ms"] = ms }
        return event("task_complete", f)
    }

    static func agentItem(_ text: String, turn: String = "t1") -> String {
        item(["type": "AgentMessage", "id": "a-\(turn)", "phase": "final_answer",
              "content": [["type": "Text", "text": text]]], turn: turn)
    }

    static func item(_ item: [String: Any], turn: String = "t1", ts: String = ts) -> String {
        event("item_completed", ["thread_id": "th-1", "turn_id": turn, "item": item,
                                 "started_at_ms": 1, "completed_at_ms": 2], ts: ts)
    }

    static func userItem(_ text: String, turn: String = "t1") -> String {
        item(["type": "UserMessage", "id": "u-\(turn)", "content": [["type": "text", "text": text, "text_elements": []]]],
             turn: turn)
    }

    static func command(id: String, _ cmd: [String], status: String = "completed", exit: Int = 0,
                        output: String = "", source: String = "unified_exec_startup") -> String {
        item(["type": "CommandExecution", "id": id, "process_id": "p", "command": cmd, "cwd": "file:///r/ios",
              "parsed_cmd": [], "source": source, "status": status, "aggregated_output": output,
              "exit_code": exit, "duration": ["secs": 0, "nanos": 1]])
    }

    static func toolOutput(call: String, _ output: Any) -> String {
        line("response_item", ["type": "custom_tool_call_output", "call_id": call, "output": output])
    }

    static func usage(id: String = "resp-1", input: Int, cached: Int, write: Int, output: Int) -> String {
        let u: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write,
                                "output_tokens": output, "reasoning_output_tokens": 7, "total_tokens": input + output]
        return line("token_usage_record", ["thread_id": "th-1", "turn_id": "t1", "session_id": "th-1",
                                           "response_id": id, "usage": u, "turn_token_usage": u,
                                           "thread_token_usage": u])
    }
}

struct CodexObsParserTests {

    /// 줄들을 차례로 먹이고 줄마다의 결과를 돌려준다. 줄 번호는 1부터.
    func run(_ lines: [String], parser: inout CodexObsParser) -> [[ObsParser.Event]?] {
        lines.enumerated().map { parser.parse(Fx.data($0.element), lineNo: $0.offset + 1) }
    }

    func run(_ lines: [String]) -> [[ObsParser.Event]?] {
        var p = CodexObsParser()
        return run(lines, parser: &p)
    }

    /// 머리 뒤 마지막 줄의 이벤트.
    func last(_ lines: [String]) throws -> [ObsParser.Event] {
        try #require(run([CFx.meta()] + lines).last ?? nil)
    }

    func one(_ lines: [String]) throws -> ObsParser.Event {
        let events = try last(lines)
        #expect(events.count == 1)
        return try #require(events.first)
    }

    @Test func headerFillsState() throws {
        let s = try #require(CodexObsParser.header(Fx.data(CFx.meta())))
        #expect(s.sessionId == "th-1" && s.rootSessionId == "th-1" && s.cwd == "/r/ios" && s.gitBranch == "feat/#54/x")
        #expect(s.originator == "dure" && s.isSubagent == false && s.parentThreadId == nil && s.model == nil && !s.skip)
        #expect(CodexObsParser.header(Fx.data(CFx.turnContext())) == nil)
        #expect(CodexObsParser.header(Fx.data("{nope")) == nil)

        var p = CodexObsParser()
        #expect(p.parse(Fx.data(CFx.meta()), lineNo: 1) == [.ignored])
        #expect(p.state == s)
    }

    @Test func turnStartFromUserMessage() throws {
        guard case let .turnStart(ctx, prompt, kind, mode) = try one([CFx.taskStarted(), CFx.userItem("iOS 로 옮겨줘")]) else {
            Issue.record("턴 시작이 아님"); return
        }
        #expect(prompt == "iOS 로 옮겨줘" && kind == .human && mode == nil)
        #expect(ctx.sessionId == "th-1" && ctx.cwd == "/r/ios" && ctx.ts == CFx.epoch && !ctx.isSidechain)
        // 브랜치는 수집기의 reflog 복원이 정한다. 출처는 originator 로 가르지 않는다.
        #expect(ctx.gitBranch == nil && ctx.entrypoint == "codex")
    }

    /// 이벤트 모양 사용자 글 · 답은 가져온 Claude 세션에만 있다 — 턴으로 세지 않는다.
    @Test func eventFormMessagesAreIgnored() throws {
        #expect(try one([CFx.taskStarted(), CFx.userMessageEvent("x")]) == .ignored)
        #expect(try one([CFx.event("agent_message", ["message": "y", "phase": "final_answer"])]) == .ignored)
    }

    /// `history_mode: legacy` = Codex Desktop 이 가져온 Claude 세션. Claude 쪽에서 이미 세므로 파일 전체를 건너뛴다.
    @Test func importedLegacySessionSkipped() throws {
        let legacy = CFx.meta(historyMode: "legacy")
        #expect(try #require(CodexObsParser.header(Fx.data(legacy))).skip)
        let out = run([legacy, CFx.taskStarted(), CFx.userMessageEvent("옮겨줘"), CFx.userItem("옮겨줘"),
                       CFx.command(id: "c", ["ls"]), CFx.usage(input: 1, cached: 0, write: 0, output: 1),
                       CFx.line("brand_new", [:]), "{broken"])
        #expect(out.dropLast().allSatisfy { $0 == [.ignored] })
        #expect(out.last! == nil)
    }

    @Test func dureDispatchIsPeer() throws {
        guard case let .turnStart(_, prompt, kind, _) = try one([CFx.taskStarted(trigger: "queue"),
                                                                 CFx.userItem("[두레] 조율자 배분 #3 — r")]) else {
            Issue.record(""); return
        }
        #expect(kind == .peer && prompt == "[두레] 조율자 배분 #3 — r")
    }

    @Test(arguments: [
        ("queue", "확인", PromptKind.human),
        ("user", "확인", .human),
        ("composer", "확인", .human),
        (nil, "확인", .human),
        ("automation_heartbeat_scheduled", "확인", .notice),
        ("automation_heartbeat_scheduled", "[두레] 조율자 배분 #1", .peer),
        ("user", "<task-notification> a", .notice),
        ("user", "<command-name>/review</command-name>", .command),
    ] as [(String?, String, PromptKind)])
    func turnKindFromTrigger(_ trigger: String?, _ text: String, _ kind: PromptKind) throws {
        guard case let .turnStart(_, _, k, _) = try one([CFx.taskStarted(trigger: trigger), CFx.userItem(text)]) else {
            Issue.record("턴 시작이 아님"); return
        }
        #expect(k == kind)
    }

    @Test func turnUsesLatestTurnContextCwd() throws {
        let out = run([CFx.meta(cwd: "/r/ios"), CFx.turnContext(cwd: "/r/a", turn: "t1"), CFx.userItem("1"),
                       CFx.turnContext(cwd: "/r/b", model: "gpt-x", turn: "t2"), CFx.userItem("2", turn: "t2")])
        guard case let .turnStart(c1, _, _, _) = out[2]?.first, case let .turnStart(c2, _, _, _) = out[4]?.first else {
            Issue.record("턴 시작이 아님"); return
        }
        #expect(c1.cwd == "/r/a" && c2.cwd == "/r/b")
        #expect(out[1] == [.ignored] && out[3] == [.ignored])
    }

    @Test func commandExecutionToToolUseAndResult() throws {
        let ok = try last([CFx.command(id: "c1", ["/bin/zsh", "-lc", "git status"], output: "clean\n")])
        guard ok.count == 2, case let .toolUse(ctx, id, name, target) = ok[0],
              case let .toolResult(ts, rid, isError, head, denied) = ok[1] else { Issue.record("\(ok)"); return }
        #expect(id == "c1" && name == "Bash" && target == "git status" && ctx.ts == CFx.epoch)
        #expect(ts == CFx.epoch && rid == "c1" && !isError && head == nil && !denied)

        let bad = try last([CFx.command(id: "c2", ["/bin/zsh", "-lc", "swift test"], status: "failed", exit: 1,
                                        output: "\nerror: boom\nmore")])
        guard case let .toolResult(_, rid2, isError2, head2, _) = bad[1] else { Issue.record("\(bad)"); return }
        #expect(rid2 == "c2" && isError2 && head2 == "error: boom")

        // status 가 completed 여도 종료 코드가 0 이 아니면 실패다.
        let nonzero = try last([CFx.command(id: "c3", ["ls"], exit: 2, output: "no such file")])
        guard case let .toolUse(_, _, _, t3) = nonzero[0], case let .toolResult(_, _, e3, h3, _) = nonzero[1] else {
            Issue.record("\(nonzero)"); return
        }
        #expect(t3 == "ls" && e3 && h3 == "no such file")
    }

    @Test func declinedCommandIsDenied() throws {
        let events = try last([CFx.command(id: "c1", ["/bin/zsh", "-lc", "git push --force"], status: "declined",
                                           exit: 0, output: "rejected by user")])
        guard case let .toolResult(_, _, isError, head, denied) = events[1] else { Issue.record(""); return }
        // 출력 글이 아니라 고정 문구 — 대시보드가 사람의 거절로 알아보고 툴 오류로 세지 않는다.
        #expect(isError && denied && head == CodexObsParser.declinedHead)
        #expect(UsageStats.isHumanRejection(head))
    }

    /// 출력 없는 셸 실패는 Claude 와 같은 `Exit code N` — 빈 errorHead 가 대시보드에 빈 줄로 뜨지 않게.
    @Test func emptyOutputFailureHasExitCodeHead() throws {
        for output in ["", "\n  \n"] {
            let events = try last([CFx.command(id: "c1", ["/bin/zsh", "-lc", "grep x y"], status: "failed", exit: 1,
                                               output: output)])
            guard case let .toolResult(_, _, isError, head, denied) = events[1] else { Issue.record("\(events)"); return }
            #expect(isError && !denied && head == "Exit code 1")
            #expect(UsageStats.isBareExitCode(tool: "Bash", head: head))
        }
        // 출력이 있으면 그 첫 줄 그대로.
        guard case let .toolResult(_, _, _, kept, _) = try last([CFx.command(id: "c2", ["ls"], exit: 2, output: "nope")])[1]
        else { Issue.record(""); return }
        #expect(kept == "nope")
    }

    /// 툴 시각은 항목의 `started_at_ms` · `completed_at_ms`(epoch ms → 초) — 줄 시각(끝난 때)만 쓰면 시작과 끝이 같다.
    @Test func toolTimesFromItemMilliseconds() throws {
        let item: [String: Any] = ["type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "sleep 1; ls"],
                                   "status": "completed", "aggregated_output": "", "exit_code": 0]
        let line = CFx.event("item_completed", ["thread_id": "th-1", "turn_id": "t1", "item": item,
                                                "started_at_ms": 1_795_136_388_250, "completed_at_ms": 1_795_136_400_900])
        let events = try last([line])
        guard case let .toolUse(ctx, _, _, _) = events[0], case let .toolResult(ts, _, _, _, _) = events[1] else {
            Issue.record("\(events)"); return
        }
        #expect(ctx.ts == 1_795_136_388 && ts == 1_795_136_400)
        // 항목 시각이 없거나 ms 가 아니면(옛 모양 · 지어낸 값) 줄 시각.
        guard case let .toolUse(c2, _, _, _) = try last([CFx.command(id: "c2", ["ls"])])[0],
              case let .toolResult(t2, _, _, _, _) = try last([CFx.command(id: "c2", ["ls"])])[1] else { Issue.record(""); return }
        #expect(c2.ts == CFx.epoch && t2 == CFx.epoch)
    }

    /// 셸로 감싼 꼴만 마지막 원소 — 셸 아닌 argv 는 잇는다.
    @Test func commandTargetUnwrapsOnlyShells() throws {
        #expect(CodexObsParser.commandLine(["/bin/zsh", "-lc", "git status"]) == "git status")
        #expect(CodexObsParser.commandLine(["bash", "-c", "make"]) == "make")
        #expect(CodexObsParser.commandLine(["/bin/sh", "-c", "ls"]) == "ls")
        #expect(CodexObsParser.commandLine(["git", "-c", "x=y"]) == "git -c x=y")
        #expect(CodexObsParser.commandLine(["git", "status"]) == "git status")
        #expect(CodexObsParser.commandLine("ls -la") == "ls -la")
    }

    @Test func commandTargetIsCut() throws {
        let long = String(repeating: "a", count: 300)
        let events = try last([CFx.command(id: "c1", ["/bin/zsh", "-lc", long])])
        guard case let .toolUse(_, _, _, target) = events[0] else { Issue.record(""); return }
        #expect(target?.count == 120)
    }

    @Test func fileChangeIsEdit() throws {
        let events = try last([CFx.item(["type": "FileChange", "id": "f1",
                                         "changes": ["/r/ios/B.swift": ["type": "update", "content": "x"],
                                                     "/r/ios/A.swift": ["type": "add", "content": "y"]],
                                         "status": "completed", "stdout": "ok", "stderr": ""])])
        guard events.count == 2, case let .toolUse(_, id, name, target) = events[0],
              case let .toolResult(_, rid, isError, head, _) = events[1] else { Issue.record("\(events)"); return }
        #expect(id == "f1" && name == "Edit" && target == "/r/ios/A.swift")
        #expect(rid == "f1" && !isError && head == nil)

        let failed = try last([CFx.item(["type": "FileChange", "id": "f2", "changes": ["/r/x": ["type": "update"]],
                                         "status": "failed", "stdout": "", "stderr": "patch rejected\nhunk 2"])])
        guard case let .toolResult(_, _, e2, h2, _) = failed[1] else { Issue.record(""); return }
        #expect(e2 && h2 == "patch rejected")
    }

    @Test func mcpToolCallNamedLikeClaude() throws {
        let events = try last([CFx.item(["type": "McpToolCall", "id": "m1", "server": "dure", "tool": "dispatch",
                                         "arguments": ["repo": "ios", "task": "x"], "status": "completed",
                                         "result": ["content": [["type": "text", "text": "queued"]], "isError": false],
                                         "duration": ["secs": 0, "nanos": 1]])])
        guard events.count == 2, case let .toolUse(_, id, name, target) = events[0],
              case let .toolResult(_, _, isError, _, _) = events[1] else { Issue.record("\(events)"); return }
        #expect(id == "m1" && name == "mcp__dure__dispatch" && target == "ios" && !isError)

        let other = try last([CFx.item(["type": "McpToolCall", "id": "m2", "server": "notion", "tool": "search",
                                        "arguments": ["repo": "nope"], "status": "failed",
                                        "result": ["content": [["type": "text", "text": "404 not found\nbody"]],
                                                   "isError": true]])])
        guard case let .toolUse(_, _, n2, t2) = other[0], case let .toolResult(_, _, e2, h2, _) = other[1] else {
            Issue.record(""); return
        }
        #expect(n2 == "mcp__notion__search" && t2 == nil && e2 && h2 == "404 not found")

        // status 는 completed 여도 결과가 isError 면 실패다.
        let soft = try last([CFx.item(["type": "McpToolCall", "id": "m3", "server": "s", "tool": "t",
                                       "arguments": [:], "status": "completed",
                                       "result": ["content": [["type": "text", "text": "bad"]], "isError": true]])])
        guard case let .toolResult(_, _, e3, h3, _) = soft[1] else { Issue.record(""); return }
        #expect(e3 && h3 == "bad")
    }

    @Test func toolCountedOnceFromItems() throws {
        let out = run([
            CFx.meta(),
            CFx.line("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "call_1",
                                       "input": "git status"]),
            CFx.line("response_item", ["type": "custom_tool_call_output", "call_id": "call_1", "output": "ok"]),
            CFx.line("response_item", ["type": "function_call", "name": "dispatch", "namespace": "mcp__dure__",
                                       "call_id": "call_2", "arguments": "{}"]),
            CFx.line("response_item", ["type": "function_call_output", "call_id": "call_2", "output": "ok"]),
            CFx.command(id: "call_1", ["/bin/zsh", "-lc", "git status"]),
        ])
        let uses = out.compactMap { $0 }.flatMap { $0 }.filter { if case .toolUse = $0 { true } else { false } }
        #expect(uses.count == 1)
        #expect(out[1...4].allSatisfy { $0 == [.ignored] })
    }

    @Test func usageRecordMapsTokens() throws {
        guard case let .assistant(ctx, text, messageId, model, usage) =
                try one([CFx.turnContext(model: "gpt-5.5-codex"),
                         CFx.usage(id: "resp-9", input: 1000, cached: 600, write: 100, output: 50)]) else {
            Issue.record(""); return
        }
        #expect(text == nil && messageId == "resp-9" && model == "gpt-5.5-codex" && ctx.sessionId == "th-1")
        #expect(usage == ObsParser.Usage(input: 300, output: 50, cacheCreation: 100, cacheRead: 600))
    }

    /// 답은 `item_completed AgentMessage`(content 블록 type `Text`)로만 남는다(실측).
    @Test func agentMessageIsAnswerText() throws {
        guard case let .assistant(_, text, messageId, model, usage) =
                try one([CFx.turnContext(model: "m1"),
                         CFx.item(["type": "AgentMessage", "id": "a1", "phase": "final_answer",
                                   "content": [["type": "Text", "text": "첫 줄"], ["type": "Text", "text": "둘"]]])]) else {
            Issue.record(""); return
        }
        #expect(text == "첫 줄\n둘" && messageId == nil && model == "m1" && usage == .init())
    }

    @Test func taskCompleteDuration() throws {
        #expect(try one([CFx.taskStarted(), CFx.userItem("x"), CFx.taskComplete(ms: 12_162)]) == .turnDuration(ms: 12_162))
        // 옛 판은 duration_ms 없이 시각(초)만 남긴다.
        #expect(try one([CFx.taskStarted(), CFx.userItem("x"),
                         CFx.event("task_complete", ["turn_id": "t1", "started_at": 10, "completed_at": 22])])
                == .turnDuration(ms: 12_000))
        #expect(try one([CFx.taskStarted(), CFx.userItem("x"), CFx.taskComplete(ms: nil)]) == .ignored)
    }

    /// 압축은 사용자 글 없는 별도 턴이다 — 그 끝(20ms)이 앞 사용자 턴의 시간을 덮지 않는다(실측 7절).
    @Test func compactionTurnDoesNotOverwriteDuration() throws {
        let out = run([CFx.meta(), CFx.taskStarted(), CFx.userItem("x"),
                       CFx.event("turn_aborted", ["turn_id": "t1", "reason": "interrupted", "duration_ms": 2455]),
                       CFx.taskStarted(turn: "c1", attribution: false),
                       CFx.line("compacted", ["message": "", "replacement_history": []]),
                       CFx.item(["type": "ContextCompaction", "id": "cc1"], turn: "c1"),
                       CFx.taskComplete(turn: "c1", ms: 20)])
        #expect(out[3] == [.interrupted] && out[5] == [.compacted] && out[6] == [.ignored] && out[7] == [.ignored])
    }

    /// 사람이 친 `!명령` 턴 — 툴도 아니고, 그 턴의 끝이 앞 턴 시간을 덮지도 않는다.
    @Test func userShellCommandIgnored() throws {
        let out = run([CFx.meta(), CFx.taskStarted(), CFx.userItem("x"), CFx.taskComplete(ms: 900),
                       CFx.taskStarted(turn: "t2"), CFx.command(id: "c", ["/bin/zsh", "-lc", "ls"], source: "user_shell"),
                       CFx.taskComplete(turn: "t2", ms: 5)])
        #expect(out[3] == [.turnDuration(ms: 900)] && out[5] == [.ignored] && out[6] == [.ignored])
    }

    /// 이어 읽기 — 이번에 시작을 못 본 턴의 끝은 지금 턴의 끝으로 받는다(긴 턴 중간에 수집이 돌아도).
    /// 이어 읽기 뒤 시작을 본 압축 턴의 끝은 사용자 턴 끝이 아니다.
    @Test func resumedThenCompactionTurnEndIgnored() throws {
        var p = CodexObsParser(state: try #require(CodexObsParser.header(Fx.data(CFx.meta()))))
        #expect(p.parse(Fx.data(CFx.taskStarted(turn: "c1", attribution: false)), lineNo: 50) == [.ignored])
        #expect(p.parse(Fx.data(CFx.taskComplete(turn: "c1", ms: 20)), lineNo: 51) == [.ignored])
    }

    @Test func resumedTurnEndIsKept() throws {
        var p = CodexObsParser(state: try #require(CodexObsParser.header(Fx.data(CFx.meta()))))
        #expect(p.parse(Fx.data(CFx.taskComplete(turn: "t9", ms: 700)), lineNo: 50) == [.turnDuration(ms: 700)])
        var q = CodexObsParser(state: try #require(CodexObsParser.header(Fx.data(CFx.meta()))))
        #expect(q.parse(Fx.data(CFx.event("turn_aborted", ["turn_id": "t9", "reason": "interrupted"])), lineNo: 50)
                == [.interrupted])
    }

    @Test func abortedIsInterrupted() throws {
        #expect(try one([CFx.taskStarted(), CFx.userItem("x"),
                         CFx.event("turn_aborted", ["turn_id": "t1", "reason": "interrupted", "duration_ms": 5])])
                == .interrupted)
        #expect(try one([CFx.taskStarted(), CFx.userItem("x"),
                         CFx.event("turn_aborted", ["turn_id": "other", "reason": "interrupted"])]) == .ignored)
    }

    @Test func compactedOnce() throws {
        let out = run([CFx.meta(), CFx.item(["type": "ContextCompaction", "id": "cc1"]),
                       CFx.line("compacted", ["message": "", "replacement_history": []])])
        let compacted = out.compactMap { $0 }.flatMap { $0 }.filter { $0 == .compacted }
        #expect(compacted.count == 1)
    }

    /// 패치 검증 실패는 `FileChange` 없이 툴 출력 글에만 남는다 — 직접 호출(글) · code-mode(블록 배열) 둘 다.
    @Test func applyPatchVerificationFailureIsEditError() throws {
        let direct = try last([CFx.toolOutput(call: "call_11", "apply_patch verification failed: Failed to read file to update /r/x.txt: No such file or directory (os error 2)")])
        guard direct.count == 2, case let .toolUse(_, id, name, target) = direct[0],
              case let .toolResult(_, rid, isError, head, denied) = direct[1] else { Issue.record("\(direct)"); return }
        #expect(id == "call_11" && name == "Edit" && target == nil && rid == "call_11" && isError && !denied)
        #expect(head?.hasPrefix("apply_patch verification failed: Failed to read file") == true)

        let code = try last([CFx.toolOutput(call: "call_9", [
            ["type": "input_text", "text": "Script failed\nWall time 0.0 seconds\nOutput:\n"],
            ["type": "input_text", "text": "Script error:\napply_patch verification failed: Failed to find expected lines in /r/a.txt:\nnomatch"],
        ])])
        guard case let .toolResult(_, _, e2, h2, _) = code[1] else { Issue.record("\(code)"); return }
        #expect(e2 && h2 == "apply_patch verification failed: Failed to find expected lines in /r/a.txt:")

        #expect(try one([CFx.toolOutput(call: "call_8", "Exit code: 0\nOutput:\nSuccess. Updated the following files:\nM a.txt\n")])
                == .ignored)

        // 성공한 명령의 출력이 문구를 담기만 한 것(코드 검색 등)은 실패가 아니다 — code-mode · 직접 둘 다.
        #expect(try one([CFx.toolOutput(call: "call_20", [
            ["type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"],
            ["type": "input_text", "text": "foo.swift:195:  if text.contains(\"apply_patch verification failed\") {\n"],
        ])]) == .ignored)
        #expect(try one([CFx.toolOutput(call: "call_21",
                                        "Exit code: 0\nOutput:\napply_patch verification failed: (grep 결과)\n")]) == .ignored)
        #expect(try one([CFx.toolOutput(call: "call_22", [
            ["type": "input_text", "text": "Script failed\nWall time 0.0 seconds\nOutput:\n"],
            ["type": "input_text", "text": "Script error:\nTypeError: x is not a function (\"apply_patch verification failed\")"],
        ])]) == .ignored)
    }

    /// 서브에이전트 띄우기는 `SubAgentActivity started` 하나로 센다 — `completed` · 협업 툴(`wait` 등)은 무시.
    @Test func subagentStartedIsAgentOthersIgnored() throws {
        guard case let .toolUse(_, id, name, target) = try one([CFx.item(["type": "SubAgentActivity", "id": "call_14",
                                                                          "kind": "started", "model": "m",
                                                                          "agent_thread_id": "th-sub",
                                                                          "agent_path": "/root/sub1"])]) else {
            Issue.record(""); return
        }
        #expect(id == "call_14" && name == "Agent" && target == "/root/sub1")
        #expect(try one([CFx.item(["type": "SubAgentActivity", "id": "subagent-completed-x", "kind": "completed",
                                   "agent_thread_id": "th-sub", "agent_path": "/root/sub1"])]) == .ignored)
        #expect(try one([CFx.item(["type": "CollabAgentToolCall", "id": "call_15", "tool": "wait", "status": "completed",
                                   "receiver_agents": [], "agents_states": [:]])]) == .ignored)
        #expect(try one([CFx.item(["type": "CollabAgentToolCall", "id": "c2", "tool": "spawn_agent",
                                   "receiver_agents": [["agent_nickname": "Hypatia"]]])]) == .ignored)
    }

    @Test func subagentFileUsesRootSessionAndOwnEventId() throws {
        let sub = CFx.meta(session: "th-sub", root: "th-1", threadSource: "subagent",
                           extra: ["parent_thread_id": "th-1",
                                   "source": ["subagent": ["thread_spawn": ["parent_thread_id": "th-1", "depth": 1,
                                                                            "agent_nickname": "Harvey"]]]])
        let s = try #require(CodexObsParser.header(Fx.data(sub)))
        #expect(s.isSubagent && s.parentThreadId == "th-1" && s.sessionId == "th-sub" && s.rootSessionId == "th-1")

        let started = CFx.event("task_started", ["turn_id": "st1", "turn_attribution": [
            "turn_id": "st1", "turn_trigger": NSNull(), "parent_turn_id": "t1", "root_turn_id": "t1"]])
        let out = run([sub, started, CFx.userItem("하위 작업", turn: "st1"), CFx.command(id: "c1", ["ls"]),
                       CFx.usage(input: 10, cached: 0, write: 0, output: 1), CFx.taskComplete(turn: "st1", ms: 151)])
        #expect(out[2] == [.ignored])
        guard case let .toolUse(ctx, _, _, _) = out[3]?.first, case let .assistant(actx, _, _, _, _) = out[4]?.first else {
            Issue.record("\(out)"); return
        }
        #expect(ctx.isSidechain && actx.isSidechain && ctx.sessionId == "th-1" && actx.sessionId == "th-1")
        #expect(ctx.eventId == "th-sub:4")
        // 서브 턴의 끝은 부모 턴의 시간이 아니다.
        #expect(out[5] == [.ignored])
        var p = CodexObsParser()
        _ = run([sub, started], parser: &p)
        #expect(p.parse(Fx.data(CFx.event("turn_aborted", ["turn_id": "st1", "reason": "interrupted"])), lineNo: 3)
                == [.ignored])
        // 이어 읽기로 시작을 못 본 서브 턴의 끝도 마찬가지.
        var q = CodexObsParser(state: s)
        #expect(q.parse(Fx.data(CFx.taskComplete(turn: "st9", ms: 80)), lineNo: 9) == [.ignored])
    }

    @Test func subagentMarkFromThreadSourceOrParent() throws {
        let s = try #require(CodexObsParser.header(Fx.data(CFx.meta(threadSource: "subagent"))))
        #expect(s.isSubagent && s.parentThreadId == nil)
        let p = try #require(CodexObsParser.header(Fx.data(CFx.meta(extra: ["parent_thread_id": "th-0"]))))
        #expect(p.isSubagent && p.parentThreadId == "th-0")
    }

    @Test func knownCodexTypesAreIgnoredNotUnknown() throws {
        let lines = [
            CFx.line("world_state", ["x": 1]),
            CFx.line("inter_agent_communication_metadata", ["x": 1]),
            CFx.event("token_count", ["info": NSNull(), "rate_limits": [:]]),
            CFx.event("thread_settings_applied"),
            CFx.taskStarted(),
            CFx.line("response_item", ["type": "message", "role": "user", "content": []]),
            CFx.line("response_item", ["type": "reasoning", "summary": []]),
            CFx.line("response_item", ["type": "additional_tools", "tools": []]),
            CFx.line("response_item", ["type": "configuration_update"]),
            CFx.line("response_item", ["type": "agent_message", "content": []]),
        ] + ["Reasoning", "Extension", "ImageView", "CollabAgentToolCall", "HookPrompt", "Plan", "DynamicToolCall",
             "WebSearch", "ImageGeneration", "Sleep", "EnteredReviewMode", "ExitedReviewMode"].map {
            CFx.item(["type": $0, "id": "i"])
        }
        let out = run([CFx.meta()] + lines)
        #expect(out.dropFirst().allSatisfy { $0 == [.ignored] })

        #expect(try one([CFx.line("brand_new", [:])]) == .unknownType("brand_new"))
        #expect(try one([CFx.event("brand_new")]) == .unknownType("event_msg.brand_new"))
        #expect(try one([CFx.line("response_item", ["type": "brand_new"])]) == .unknownType("response_item.brand_new"))
        #expect(try one([CFx.item(["type": "BrandNew", "id": "b"])]) == .unknownType("item.BrandNew"))
    }

    @Test func brokenLineIsNil() {
        var p = CodexObsParser()
        _ = p.parse(Fx.data(CFx.meta()), lineNo: 1)
        #expect(p.parse(Fx.data("{\"type\":\"event_msg\",\"payl"), lineNo: 2) == nil)
        #expect(p.parse(Fx.data("{\"payload\":{}}"), lineNo: 3) == nil)
        #expect(p.parse(Fx.data(Fx.json(["type": "event_msg", "timestamp": CFx.ts])), lineNo: 4) == nil)
        #expect(p.parse(Fx.data(CFx.userItem("x").replacingOccurrences(of: CFx.ts, with: "어제")), lineNo: 5) == nil)
    }

    @Test func linesBeforeHeaderAreIgnoredNotBroken() {
        let out = run([CFx.userItem("x"), CFx.command(id: "c", ["ls"]), CFx.event("task_complete", ["duration_ms": 1])])
        #expect(out.allSatisfy { $0 == [.ignored] })
    }

    @Test func eventIdFromSessionAndLine() throws {
        let out = run([CFx.meta(), CFx.turnContext(), CFx.userItem("x")])
        guard case let .turnStart(ctx, _, _, _) = out[2]?.first else { Issue.record(""); return }
        #expect(ctx.eventId == "th-1:3")
    }

    /// 이어 읽기 — 수집기가 첫 줄로 머리를 다시 채운 상태로 중간부터 읽는다.
    @Test func resumedFromHeaderKeepsSession() throws {
        var p = CodexObsParser(state: try #require(CodexObsParser.header(Fx.data(CFx.meta()))))
        guard case let .turnStart(ctx, _, _, _) = p.parse(Fx.data(CFx.userItem("이어서")), lineNo: 40)?.first else {
            Issue.record(""); return
        }
        #expect(ctx.sessionId == "th-1" && ctx.eventId == "th-1:40")
    }

    // MARK: - 실측 rollout 통째로 (docs/spikes/2026-11-19-codex/k-stage5-tools/samples 의 정리본, 가짜 모델 대본뿐)

    func sample(_ name: String) throws -> [[ObsParser.Event]?] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        return run(lines)
    }

    @Test func sampleMainRolloutEndToEnd() throws {
        let out = try sample("codex-rollout-main.jsonl")
        #expect(out.count == 193 && out.allSatisfy { $0 != nil })
        let events = out.compactMap { $0 }.flatMap { $0 }
        #expect(!events.contains { if case .unknownType = $0 { true } else { false } })

        let starts = events.compactMap { e -> (PromptKind, ObsParser.Context)? in
            if case let .turnStart(ctx, _, kind, _) = e { (kind, ctx) } else { nil }
        }
        // 사용자 턴 10(두레 큐 배분 2 — 첫 턴 · 돌던 중에 넣은 것), 압축 턴은 턴이 아니다.
        #expect(starts.count == 10)
        #expect(starts.map(\.0) == [.peer] + Array(repeating: .human, count: 8) + [.peer])
        #expect(starts.allSatisfy { $0.1.sessionId == "01a1f907-8088-7c32-807a-74c16a4ed148" && $0.1.gitBranch == nil })

        let uses = events.compactMap { e -> String? in if case let .toolUse(_, _, name, _) = e { name } else { nil } }
        // 셸 7(code-mode 4 · 직접 1 · 중단 뒤 끝난 1 · 3초 1) · 수정 2 · 패치 검증 실패 3 · 서브에이전트 띄우기 2
        // (`SubAgentActivity started` — 협업 `wait` 둘 · `completed` 둘은 안 센다).
        #expect(uses.filter { $0 == "Bash" }.count == 7)
        #expect(uses.filter { $0 == "Edit" }.count == 5)
        #expect(uses.filter { $0 == "Agent" }.count == 2)
        #expect(uses.count == 14)
        let errors = events.filter { if case let .toolResult(_, _, isError, _, _) = $0 { isError } else { false } }
        #expect(errors.count == 5)   // 셸 실패 2 · 패치 검증 실패 3
        // 툴 시각은 항목의 시작 · 끝 — 중단 뒤 끝난 셸 30초 · `sleep 3` 셸 3초가 보인다(줄 시각만 쓰면 0).
        var started: [String: Int] = [:], spans: [Int] = []
        for e in events {
            if case let .toolUse(ctx, id, "Bash", _) = e { started[id] = ctx.ts }
            if case let .toolResult(ts, id, _, _, _) = e, let s = started[id] { spans.append(ts - s) }
        }
        #expect(spans.sorted() == [0, 0, 0, 0, 0, 3, 30])

        let usage = events.filter { if case let .assistant(_, nil, id?, _, _) = $0 { !id.isEmpty } else { false } }
        #expect(usage.count == 26)
        // 중단된 턴 뒤 압축 턴의 20ms 가 턴 시간으로 나오지 않는다.
        let durations = events.compactMap { e -> Int? in if case let .turnDuration(ms) = e { ms } else { nil } }
        #expect(durations == [590, 428, 153, 68, 132, 240, 136, 3130, 40])
        #expect(events.filter { $0 == .interrupted }.count == 1 && events.filter { $0 == .compacted }.count == 1)
    }

    @Test func sampleSubagentRolloutEndToEnd() throws {
        let out = try sample("codex-rollout-subagent.jsonl")
        #expect(out.allSatisfy { $0 != nil })
        let events = out.compactMap { $0 }.flatMap { $0 }
        #expect(!events.contains { if case .turnStart = $0 { true } else { false } })
        #expect(!events.contains { if case .turnDuration = $0 { true } else { false } })
        let uses = events.compactMap { e -> ObsParser.Context? in if case let .toolUse(ctx, _, _, _) = e { ctx } else { nil } }
        #expect(uses.count == 2)
        #expect(uses.allSatisfy { $0.isSidechain && $0.sessionId == "01a1f907-8088-7c32-807a-74c16a4ed148" })
        #expect(uses.allSatisfy { $0.eventId?.hasPrefix("01a1f90b-eb39-7e80-b4c1-4f21e85c4854:") == true })
    }
}
