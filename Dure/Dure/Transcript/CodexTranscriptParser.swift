import Foundation

/// Codex rollout(`~/.codex/sessions/.../rollout-*.jsonl`) 한 줄을 F6 · F7 이 쓸 값으로 바꾼다.
/// 줄 모양은 codex-cli 0.167.0 실측: `{"timestamp","ordinal","type","payload"}`.
/// 순수 함수만 둔다.
nonisolated enum CodexTranscriptParser {

    enum Parsed {
        case model(String)
        case usage(TranscriptParser.Usage, ts: Int?)
        case tool(TranscriptParser.Tool, ts: Int?)
    }

    static func parse(_ data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              let payload = root["payload"] as? [String: Any]
        else { return nil }
        let ts = TranscriptParser.timestamp(root)

        switch type {
        case "turn_context":
            guard let model = payload["model"] as? String else { return nil }
            return .model(model)

        case "token_usage_record":
            // 응답 하나의 사용량은 `usage`. turn_/thread_token_usage 는 누적이라 쓰지 않는다.
            guard let id = payload["response_id"] as? String,
                  let u = payload["usage"] as? [String: Any] else { return nil }
            let input = u["input_tokens"] as? Int ?? 0
            let cached = u["cached_input_tokens"] as? Int ?? 0
            let write = u["cache_write_input_tokens"] as? Int ?? 0
            return .usage(TranscriptParser.Usage(
                messageId: id,
                input: max(0, input - cached - write),
                output: u["output_tokens"] as? Int ?? 0,
                cacheRead: cached,
                cacheCreation: write,
                thinking: u["reasoning_output_tokens"] as? Int ?? 0,
                serviceTier: nil,
                model: nil), ts: ts)

        case "response_item":
            guard let kind = payload["type"] as? String,
                  kind == "custom_tool_call" || kind == "function_call",
                  let name = payload["name"] as? String else { return nil }
            // MCP 툴은 `item_completed` 에서만 센다. 직접 호출은 둘 다 남겨 두 번 세게 된다.
            if let ns = payload["namespace"] as? String, ns.hasPrefix("mcp__") { return nil }
            return .tool(classify(namespace: payload["namespace"] as? String, name: name), ts: ts)

        case "event_msg":
            // code-mode `exec` 안의 MCP 호출은 function_call 줄이 없고 이 줄만 남는다.
            guard payload["type"] as? String == "item_completed",
                  let item = payload["item"] as? [String: Any],
                  item["type"] as? String == "McpToolCall",
                  let server = item["server"] as? String,
                  let tool = item["tool"] as? String else { return nil }
            return .tool(TranscriptParser.classify(name: "mcp__\(server)__\(tool)", input: nil), ts: ts)

        default:
            return nil
        }
    }

    /// MCP 툴의 이름을 Claude 와 같은 `mcp__<서버>__<툴>` 로 맞춘다. 대응을 이 한 곳에 둔다.
    static func classify(namespace: String?, name: String) -> TranscriptParser.Tool {
        if let ns = namespace, ns.hasPrefix("mcp__") {
            return TranscriptParser.classify(name: "\(ns)__\(name)", input: nil)
        }
        return TranscriptParser.classify(name: name, input: nil)
    }
}
