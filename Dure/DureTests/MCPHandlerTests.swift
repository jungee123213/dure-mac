import Foundation
import Testing
@testable import Dure

/// 단계 4 — Claude Code 가 `nc -U` 너머로 보내는 JSON-RPC. 실측 순서:
/// `server/discover`(문자열 id) → `initialize` → `notifications/initialized` → `tools/list` → `tools/call`.
struct MCPHandlerTests {

    static let tools: [[String: Any]] = [[
        "name": "echo", "description": "d",
        "inputSchema": ["type": "object", "properties": ["x": ["type": "string"]], "required": ["x"]],
    ]]

    static func respond(_ line: String, call: (MCPToolCall) -> MCPToolResult = { _ in .init(text: "") }) -> [String: Any]? {
        guard let out = MCPHandler.respond(toLine: line, tools: tools, serverName: "dure", call: call) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    }

    @Test func discover_는_문자열_id_로_빈_result() throws {
        let r = try #require(Self.respond(#"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{}}"#))
        #expect(r["id"] as? String == "server-discover-probe-1")
        #expect((r["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test func initialize_는_받은_버전을_되돌린다() throws {
        let r = try #require(Self.respond(#"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}},"jsonrpc":"2.0","id":0}"#))
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "dure")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(r["id"] as? Int == 0)
    }

    // Task 1 M3 에서 Codex 0.167.0 이 실제로 보낸 줄(g-stage2.md)
    static let codexInit = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.167.0"}}}"#
    static let codexCall = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"_meta":{"callId":"exec-e733f2b9-e1af-4ebd-91a9-0bb6dcea6841","threadId":"01a1f6a3-x","progressToken":1},"name":"echo","arguments":{"x":"s2"}}}"#

    @Test func Codex_클라이언트의_initialize_에_답한다() throws {
        let r = try #require(Self.respond(Self.codexInit))
        #expect(r["id"] as? Int == 0)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "dure")
        let list = try #require(Self.respond(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"progressToken":0}}}"#))
        #expect(((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String == "echo")
    }

    @Test func Codex_클라이언트의_tools_call_은_toolUseId_없이도_된다() throws {
        let r = try #require(Self.respond(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"x":"s2"}}}"#) { c in
            .init(text: "받음: \(c.arguments["x"] ?? "")")
        })
        let content = try #require(((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        #expect(content["text"] as? String == "받음: s2")
    }

    @Test func Codex_의_callId_를_toolUseId_대신_쓴다() {
        var got: MCPToolCall?
        _ = Self.respond(Self.codexCall) { c in got = c; return .init(text: "") }
        #expect(got?.toolUseId == "exec-e733f2b9-e1af-4ebd-91a9-0bb6dcea6841")
        // 둘 다 있으면 claudecode/toolUseId 가 먼저
        _ = Self.respond(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"claudecode/toolUseId":"toolu_9","callId":"exec-1"},"name":"echo","arguments":{}}}"#) { c in got = c; return .init(text: "") }
        #expect(got?.toolUseId == "toolu_9")
    }

    @Test func 알림에는_답하지_않는다() {
        #expect(MCPHandler.respond(toLine: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                   tools: Self.tools, serverName: "dure", call: { _ in .init(text: "") }) == nil)
    }

    @Test func tools_list_는_정의를_그대로_준다() throws {
        let r = try #require(Self.respond(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#))
        let list = try #require((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(list.first?["name"] as? String == "echo")
    }

    @Test func tools_call_은_이름_인자_toolUseId_를_넘기고_텍스트로_답한다() throws {
        var got: MCPToolCall?
        let r = try #require(Self.respond(
            #"{"method":"tools/call","params":{"name":"echo","arguments":{"x":"안녕 \"친구\""},"_meta":{"claudecode/toolUseId":"toolu_1"}},"jsonrpc":"2.0","id":2}"#
        ) { c in got = c; return .init(text: "받음: \(c.arguments["x"] ?? "")") })
        #expect(got == MCPToolCall(name: "echo", arguments: ["x": "안녕 \"친구\""], toolUseId: "toolu_1"))
        let content = try #require(((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        #expect(content["type"] as? String == "text" && content["text"] as? String == "받음: 안녕 \"친구\"")
        #expect((r["result"] as? [String: Any])?["isError"] == nil)
    }

    /// 툴 에러는 JSON-RPC 에러가 아니라 `isError` 다 — 모델이 읽고 고칠 수 있어야 한다.
    @Test func 툴_에러는_isError_로_간다() throws {
        let r = try #require(Self.respond(#"{"method":"tools/call","params":{"name":"echo","arguments":{}},"jsonrpc":"2.0","id":3}"#) { _ in
            .init(text: "x 가 없다", isError: true)
        })
        #expect((r["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func 모르는_메서드는_빈_result_깨진_줄은_무시() {
        #expect(Self.respond(#"{"jsonrpc":"2.0","id":9,"method":"prompts/list"}"#)?["result"] != nil)
        #expect(MCPHandler.respond(toLine: "{not json", tools: Self.tools, serverName: "dure", call: { _ in .init(text: "") }) == nil)
        #expect(MCPHandler.respond(toLine: "", tools: Self.tools, serverName: "dure", call: { _ in .init(text: "") }) == nil)
    }

    @Test func 응답은_한_줄이다() throws {
        let out = try #require(MCPHandler.respond(toLine: #"{"method":"tools/call","params":{"name":"echo","arguments":{"x":"a"}},"jsonrpc":"2.0","id":4}"#,
                                                  tools: Self.tools, serverName: "dure") { _ in .init(text: "줄1\n줄2") })
        #expect(!out.contains("\n"))
    }
}
