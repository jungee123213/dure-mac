import Foundation
import GRDB
import Testing
@testable import Dure

/// Stage 4 — Codex rollout → `token_usage` · `tool_use`. 줄 모양은 codex-cli 0.167.0 실측.
struct CodexTranscriptTests {

    static let ts = "2026-11-20T01:26:56.682Z"   // 1795138016

    static func turnContext(_ model: String) -> String {
        #"{"timestamp":"\#(ts)","ordinal":1,"type":"turn_context","payload":{"turn_id":"t1","cwd":"/repo","model":"\#(model)"}}"#
    }

    static func usage(_ id: String, input: Int = 1000, cached: Int = 600, write: Int = 0,
                      output: Int = 50, reasoning: Int = 20, timestamp: String? = ts) -> String {
        let t = timestamp.map { #""timestamp":"\#($0)","# } ?? ""
        return #"{\#(t)"ordinal":2,"type":"token_usage_record","payload":{"thread_id":"th","turn_id":"t1","response_id":"\#(id)","usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(write),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":1},"turn_token_usage":{"input_tokens":99999},"thread_token_usage":{"input_tokens":99999}}}"#
    }

    static let execCall = #"{"timestamp":"\#(ts)","ordinal":3,"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"ls"}}"#
    static let mcpCall = #"{"timestamp":"\#(ts)","ordinal":4,"type":"response_item","payload":{"type":"function_call","name":"complete","namespace":"mcp__dure","arguments":"{}","call_id":"c2"}}"#
    static let waitCall = #"{"timestamp":"\#(ts)","ordinal":5,"type":"response_item","payload":{"type":"function_call","name":"wait","arguments":"{}","call_id":"c3"}}"#

    static func mcpItem(id: String) -> String {
        #"{"timestamp":"\#(ts)","ordinal":83,"type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u","item":{"type":"McpToolCall","id":"\#(id)","server":"dure","tool":"complete","arguments":{"summary":"s"},"status":"completed"}}}"#
    }

    private func makeDB(model: String? = nil) throws -> (DatabaseQueue, (String) -> CCSession) {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo", label: nil, model: nil, role: nil).insert(db)
            try Agent(dureSession: "pane", workspaceId: "w1", repoId: "r1", agentKind: "codex",
                      state: .started, model: nil, startedAt: 0, endedAt: nil).insert(db)
        }
        let make: (String) -> CCSession = { path in
            CCSession(ccSessionId: "cc1", dureSession: "pane", transcriptPath: path,
                      source: "startup", model: model, startedAt: 0)
        }
        return (q, make)
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func run(_ lines: [String], model: String? = nil, now: Int = 5)
        throws -> (DatabaseQueue, CCSession, URL) {
        let (q, make) = try makeDB(model: model)
        let url = try write(lines)
        let session = make(url.path)
        try q.write { try session.insert($0) }
        try q.write { try TranscriptIngestor.ingest(session, in: $0, now: now) }
        return (q, session, url)
    }

    @Test func codexUsageMapsColumns() throws {
        let (q, _, url) = try run([Self.turnContext("gpt-x"), Self.usage("resp_1")])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try q.read { try TokenUsage.fetchAll($0) }
        #expect(rows.count == 1)
        let r = rows[0]
        #expect(r.messageId == "resp_1")
        #expect(r.input == 400)
        #expect(r.cacheRead == 600)
        #expect(r.cacheCreation == 0)
        #expect(r.output == 50)
        #expect(r.thinking == 20)
        #expect(r.model == "gpt-x")
    }

    @Test func codexCacheWriteSubtracted() throws {
        let (q, _, url) = try run([Self.usage("a", input: 1000, cached: 600, write: 100),
                                   Self.usage("b", input: 100, cached: 90, write: 50)])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try q.read { try TokenUsage.order(Column("message_id")).fetchAll($0) }
        #expect(rows[0].input == 300)
        #expect(rows[0].cacheCreation == 100)
        #expect(rows[1].input == 0)
    }

    @Test func codexDuplicateResponseIdOneRow() throws {
        let (q, _, url) = try run([Self.usage("resp_1"), Self.usage("resp_1")])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try q.read { try TokenUsage.fetchCount($0) } == 1)
    }

    @Test func codexToolsClassified() throws {
        let (q, _, url) = try run([Self.execCall, Self.mcpItem(id: "call_13"), Self.waitCall])
        defer { try? FileManager.default.removeItem(at: url) }
        let tools = try q.read { try ToolUse.order(Column("line_no")).fetchAll($0) }
        #expect(tools.count == 3)
        #expect(tools[0].toolName == "exec")
        #expect(tools[0].mcpServer == nil)
        #expect(tools[1].toolName == "mcp__dure__complete")
        #expect(tools[1].mcpServer == "dure")
        #expect(tools[2].toolName == "wait")
        #expect(tools[2].mcpServer == nil)
    }

    @Test func codexMcpFromItemCompleted() throws {
        let (q, _, url) = try run([Self.execCall, Self.mcpItem(id: "exec-95d64086")])
        defer { try? FileManager.default.removeItem(at: url) }
        let tools = try q.read { try ToolUse.fetchAll($0) }
        #expect(tools.filter { $0.toolName == "mcp__dure__complete" && $0.mcpServer == "dure" }.count == 1)
        #expect(tools.filter { $0.toolName == "exec" }.count == 1)
    }

    @Test func codexDirectMcpCountedOnce() throws {
        let (q, _, url) = try run([Self.execCall, Self.mcpCall, Self.mcpItem(id: "call_13"), Self.waitCall])
        defer { try? FileManager.default.removeItem(at: url) }
        let tools = try q.read { try ToolUse.fetchAll($0) }
        #expect(tools.filter { $0.mcpServer != nil }.count == 1)
        #expect(tools.count == 3)
    }

    @Test func rowTimestampFromLine() throws {
        let claude = TranscriptTests.textLine.replacingOccurrences(
            of: #"{"type":"assistant","#, with: #"{"type":"assistant","timestamp":"\#(Self.ts)","#)
        let (q, _, url) = try run([claude, Self.usage("resp_1")])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try q.read { try TokenUsage.fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.ts == 1795138016 })
    }

    @Test func missingTimestampFallsBackToReadTime() throws {
        let (q, _, url) = try run([Self.usage("resp_1", timestamp: nil)], now: 777)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try q.read { try TokenUsage.fetchAll($0) }[0].ts == 777)
    }

    @Test func timestampWithoutFraction() {
        #expect(TranscriptParser.timestamp(["timestamp": "2026-11-20T01:26:56Z"]) == 1795138016)
        #expect(TranscriptParser.timestamp(["timestamp": "nope"]) == nil)
    }

    @Test func resumedBatchUsesSessionModel() throws {
        let (q, _, url) = try run([Self.usage("a"), Self.turnContext("gpt-new"), Self.usage("b")],
                                  model: "gpt-prev")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try q.read { try TokenUsage.order(Column("message_id")).fetchAll($0) }
        #expect(rows[0].model == "gpt-prev")
        #expect(rows[1].model == "gpt-new")
        #expect(try q.read { try CCSession.fetchOne($0, key: "cc1") }?.model == "gpt-new")
    }

    @Test func claudeLinesUnchanged() throws {
        let (q, _, url) = try run([TranscriptTests.thinkingLine, TranscriptTests.toolLine])
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try q.read { try TokenUsage.fetchAll($0) }
        #expect(rows.count == 1 && rows[0].model == "claude-fable-5" && rows[0].ts == 5)
        #expect(try q.read { try CCSession.fetchOne($0, key: "cc1") }?.model == nil)
    }
}
