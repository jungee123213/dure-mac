// Dure/Dure/Observer/ObsParser.swift
import Foundation

/// jsonl 한 줄 → 감시자 이벤트. **순수 함수**. 형식은 비공식이라 깨진 줄은 `nil`, 모르는 type 은 따로 센다.
nonisolated enum ObsParser {

    struct Context: Equatable, Sendable {
        var sessionId: String
        var cwd: String
        var gitBranch: String?
        var ts: Int
        var entrypoint: String?
        var isSidechain: Bool
        /// 줄의 `uuid`. 근거의 주소이자 중복 방지 열쇠.
        var eventId: String?
    }

    struct Usage: Equatable, Sendable {
        var input = 0, output = 0, cacheCreation = 0, cacheRead = 0
        /// 청구 기준 — 캐시 읽기 제외(F6 와 같은 정의).
        var headline: Int { input + cacheCreation + output }
    }

    enum Event: Equatable, Sendable {
        case turnStart(Context, prompt: String, kind: PromptKind, permissionMode: String?)
        case toolUse(Context, id: String, name: String, target: String?)
        case toolResult(ts: Int, toolUseId: String, isError: Bool, errorHead: String?, denied: Bool)
        case assistant(Context, text: String?, messageId: String?, model: String?, usage: Usage)
        case turnDuration(ms: Int)
        case interrupted
        case compacted
        case ignored
        case unknownType(String)
    }

    /// 평가에 쓰지 않는 것으로 **알고 있는** type. 여기 없는 type 은 `unknownType` — 형식 변화를 드러낸다.
    static let knownTypes: Set<String> = [
        "attachment", "last-prompt", "mode", "permission-mode", "atis-latch", "ai-title", "custom-title",
        "agent-name", "file-history-snapshot", "file-history-delta", "cost-state", "queue-operation", "summary",
        "progress", "rate_limit_event",
    ]

    static func parse(_ data: Data) -> [Event]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return nil }
        switch type {
        case "user": return user(root)
        case "assistant": return assistant(root)
        case "system":
            if root["subtype"] as? String == "turn_duration", let ms = root["durationMs"] as? Int { return [.turnDuration(ms: ms)] }
            return [.ignored]
        default:
            return knownTypes.contains(type) ? [.ignored] : [.unknownType(type)]
        }
    }

    private static func user(_ root: [String: Any]) -> [Event]? {
        guard let ctx = context(root), let message = root["message"] as? [String: Any] else { return nil }
        let content = message["content"]
        if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            let denied = root["toolDenialKind"] != nil
            return blocks.compactMap { b in
                guard b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String else { return nil }
                let isError = b["is_error"] as? Bool ?? false
                return .toolResult(ts: ctx.ts, toolUseId: id, isError: isError,
                                   errorHead: isError ? firstLine(plain(b["content"]), max: 200) : nil, denied: denied)
            }
        }
        if root["isCompactSummary"] as? Bool == true { return [.compacted] }
        let text = plain(content)
        if text.hasPrefix("[Request interrupted") { return [.interrupted] }
        if ctx.isSidechain { return [.ignored] }
        let origin = root["origin"] as? [String: Any]
        if root["isMeta"] as? Bool == true {
            // 두레 배분(인박스 소켓)은 메타로 찍히지만 사람 대신 들어온 작업 지시다.
            guard origin?["kind"] as? String == "peer" else { return [.ignored] }
            return [.turnStart(ctx, prompt: origin?["body"] as? String ?? text, kind: .peer,
                               permissionMode: root["permissionMode"] as? String)]
        }
        if text.hasPrefix("<local-command-stdout") || text.hasPrefix("<local-command-stderr") { return [.ignored] }
        let kind: PromptKind = root["promptSource"] as? String == "sdk" ? .sdk : .human
        return [.turnStart(ctx, prompt: text, kind: kind, permissionMode: root["permissionMode"] as? String)]
    }

    private static func assistant(_ root: [String: Any]) -> [Event]? {
        guard let ctx = context(root), let message = root["message"] as? [String: Any] else { return nil }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let u = message["usage"] as? [String: Any]
        let usage = Usage(input: u?["input_tokens"] as? Int ?? 0, output: u?["output_tokens"] as? Int ?? 0,
                          cacheCreation: u?["cache_creation_input_tokens"] as? Int ?? 0,
                          cacheRead: u?["cache_read_input_tokens"] as? Int ?? 0)
        var events: [Event] = [.assistant(ctx, text: text.isEmpty ? nil : text, messageId: message["id"] as? String,
                                          model: message["model"] as? String, usage: usage)]
        for b in blocks where b["type"] as? String == "tool_use" {
            guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
            events.append(.toolUse(ctx, id: id, name: name, target: target(name: name, input: b["input"] as? [String: Any])))
        }
        return events
    }

    static func target(name: String, input: [String: Any]?) -> String? {
        switch name {
        case "Read", "Edit", "Write", "MultiEdit": return input?["file_path"] as? String
        case "NotebookEdit": return input?["notebook_path"] as? String
        case "Bash": return (input?["command"] as? String).map { String($0.prefix(120)) }
        case "Grep", "Glob": return input?["pattern"] as? String
        case "Skill": return input?["skill"] as? String
        case "Agent", "Task": return input?["subagent_type"] as? String ?? input?["description"] as? String
        // 조율자 토큰을 어느 레포 작업에 돌릴지의 근거(Task 13).
        case "mcp__dure__dispatch": return input?["repo"] as? String
        default: return nil
        }
    }

    private static func context(_ root: [String: Any]) -> Context? {
        guard let session = root["sessionId"] as? String ?? root["session_id"] as? String,
              let cwd = root["cwd"] as? String,
              let tsString = root["timestamp"] as? String, let ts = epoch(tsString) else { return nil }
        return Context(sessionId: session, cwd: cwd, gitBranch: root["gitBranch"] as? String, ts: ts,
                       entrypoint: root["entrypoint"] as? String, isSidechain: root["isSidechain"] as? Bool ?? false,
                       eventId: root["uuid"] as? String)
    }

    private static func plain(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    private static func firstLine(_ s: String, max: Int) -> String {
        String((s.split(separator: "\n", omittingEmptySubsequences: true).first ?? "").prefix(max))
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    static func epoch(_ s: String) -> Int? {
        (isoFractional.date(from: s) ?? iso.date(from: s)).map { Int($0.timeIntervalSince1970) }
    }
}
