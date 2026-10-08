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
