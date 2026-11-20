import Foundation

/// 트랜스크립트 한 줄을 읽어 F6·F7 이 쓸 값으로 바꾼다.
/// `docs/step1/tokens.sh` · `tools.sh` 의 Swift 이식. 규칙은 부록 A7.
/// **순수 함수만 둔다** — 실제 트랜스크립트 줄로 테스트하기 위해서다.
nonisolated enum TranscriptParser {

    struct Line {
        var usage: Usage?
        var tool: Tool?
    }

    struct Usage {
        var messageId: String
        var input: Int, output: Int, cacheRead: Int, cacheCreation: Int, thinking: Int
        var serviceTier: String?
        var model: String?
    }

    struct Tool {
        var name: String
        var mcpServer: String?
        var skillName: String?
    }

    /// `assistant` 레코드만 본다. 아니면 nil.
    static func parse(_ data: Data) -> Line? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any]
        else { return nil }

        var line = Line(usage: nil, tool: nil)

        // ── F6 토큰 (A7-1)
        if let u = message["usage"] as? [String: Any],
           let messageId = message["id"] as? String {
            let details = u["output_tokens_details"] as? [String: Any]
            line.usage = Usage(
                messageId: messageId,
                input: u["input_tokens"] as? Int ?? 0,
                output: u["output_tokens"] as? Int ?? 0,
                cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: u["cache_creation_input_tokens"] as? Int ?? 0,
                thinking: details?["thinking_tokens"] as? Int ?? 0,
                serviceTier: u["service_tier"] as? String,
                model: message["model"] as? String)
        }

        // ── F7 툴 (A7-2). content 블록 하나가 곧 한 줄이라 최대 1개다.
        if let content = message["content"] as? [[String: Any]],
           let block = content.first(where: { $0["type"] as? String == "tool_use" }),
           let name = block["name"] as? String {
            line.tool = classify(name: name, input: block["input"] as? [String: Any])
        }

        return (line.usage == nil && line.tool == nil) ? nil : line
    }

    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 줄의 `timestamp`(ISO 8601, 소수 초 · `Z`)를 유닉스 초로. Claude · Codex 줄이 같은 필드를 쓴다.
    static func timestamp(_ root: [String: Any]) -> Int? {
        guard let s = root["timestamp"] as? String else { return nil }
        guard let d = isoFraction.date(from: s) ?? isoPlain.date(from: s) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    /// 부록 A7-2 의 판별표.
    static func classify(name: String, input: [String: Any]?) -> Tool {
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__")
            // ⚠️ 서버명에 `__` 가 들어가면 split 이 깨진다.
            //    3조각이 아니면 **조용히 틀린 이름을 넣지 않고** nil 로 둔다.
            return Tool(name: name,
                        mcpServer: parts.count == 3 ? parts[1] : nil,
                        skillName: nil)
        }
        if name == "Skill" {
            // `plugin:skill` 형태를 통째로 저장한다. 쪼개지 않는다.
            return Tool(name: name, mcpServer: nil, skillName: input?["skill"] as? String)
        }
        return Tool(name: name, mcpServer: nil, skillName: nil)
    }
}
