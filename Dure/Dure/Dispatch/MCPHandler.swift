import Foundation

/// 단계 4 — Claude Code 가 부른 툴 하나. 인자는 전부 문자열(스키마가 그렇다). 다른 타입이 오면 문자열로 바꾼다.
struct MCPToolCall: Equatable {
    var name: String
    var arguments: [String: String]
    /// `params._meta["claudecode/toolUseId"]`. 이력에 남겨 조율자 트랜스크립트와 맞춰본다.
    var toolUseId: String?
}

struct MCPToolResult: Equatable {
    var text: String
    var isError: Bool = false
}

/// 단계 4 — 줄 단위 JSON-RPC 의 순수한 부분. 소켓은 `MCPServer`, 툴의 뜻은 `DureTools` 와 스토어.
///
/// 실측(2026-10-08, claude 2.1.293): `server/discover`(id 가 **문자열**) → `initialize` → `notifications/initialized`
/// → `tools/list` → `tools/call`. 모르는 메서드에는 빈 `result` 를 주면 된다. 툴 실패는 JSON-RPC 에러가 아니라
/// `result.isError` 로 — 모델이 읽고 고칠 수 있게.
enum MCPHandler {

    static func respond(toLine line: String, tools: [[String: Any]], serverName: String,
                        call: (MCPToolCall) -> MCPToolResult) -> String? {
        guard let data = line.data(using: .utf8), !line.isEmpty,
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = req["method"] as? String else { return nil }
        // id 가 없으면 알림이다. 답하지 않는다.
        guard let id = req["id"] else { return nil }
        let params = req["params"] as? [String: Any] ?? [:]

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-11-25",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": "1"],
            ]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let raw = params["arguments"] as? [String: Any] ?? [:]
            let args = raw.mapValues { v -> String in
                if let s = v as? String { return s }
                return "\(v)"
            }
            let meta = params["_meta"] as? [String: Any]
            let r = call(MCPToolCall(name: name, arguments: args, toolUseId: (meta?["claudecode/toolUseId"] as? String) ?? (meta?["callId"] as? String)))
            var out: [String: Any] = ["content": [["type": "text", "text": r.text]]]
            if r.isError { out["isError"] = true }
            result = out
        default:
            result = [:]
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        // withoutEscapingSlashes 는 경로가 읽기 쉽게. 줄바꿈은 JSON 이 `\n` 으로 이스케이프하므로 한 줄이다.
        guard let out = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes, .sortedKeys]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}
