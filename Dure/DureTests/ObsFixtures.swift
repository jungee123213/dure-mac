// Dure/DureTests/ObsFixtures.swift
import Foundation
import GRDB
@testable import Dure

/// 감시자 테스트용 jsonl 줄. **실측한 레코드 모양**(Task 2 머리)을 그대로 따른다.
enum Fx {
    static func memoryDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    static func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    static func data(_ s: String) -> Data { Data(s.utf8) }

    static func base(_ type: String, session: String, cwd: String, branch: String?, ts: String,
                     sidechain: Bool = false, uuid: String = UUID().uuidString) -> [String: Any] {
        var o: [String: Any] = ["type": type, "sessionId": session, "cwd": cwd, "timestamp": ts,
                                "entrypoint": "cli", "isSidechain": sidechain, "uuid": uuid]
        if let branch { o["gitBranch"] = branch }
        return o
    }

    static func human(_ text: String, session: String = "s1", cwd: String = "/r/ios", branch: String? = "feat/#52/x",
                      ts: String = "2026-10-10T01:00:00.000Z", source: String = "typed",
                      uuid: String = UUID().uuidString) -> String {
        var o = base("user", session: session, cwd: cwd, branch: branch, ts: ts, uuid: uuid)
        o["message"] = ["role": "user", "content": text]
        o["origin"] = ["kind": "human"]
        o["promptSource"] = source
        o["permissionMode"] = "default"
        return json(o)
    }

    static func peer(_ body: String, session: String = "s1", cwd: String = "/r/ios", branch: String? = "feat/#52/x",
                     ts: String = "2026-10-10T01:00:00.000Z") -> String {
        var o = base("user", session: session, cwd: cwd, branch: branch, ts: ts)
        o["message"] = ["role": "user", "content": "Another Claude session sent a message:\n\(body)"]
        o["isMeta"] = true
        o["origin"] = ["kind": "peer", "body": body]
        return json(o)
    }

    static func meta(_ text: String) -> String {
        var o = base("user", session: "s1", cwd: "/r/ios", branch: "feat/#52/x", ts: "2026-10-10T01:00:01.000Z")
        o["message"] = ["role": "user", "content": [["type": "text", "text": text]]]
        o["isMeta"] = true
        return json(o)
    }

    static func toolUse(_ id: String, name: String, input: [String: Any], session: String = "s1",
                        cwd: String = "/r/ios", ts: String = "2026-10-10T01:00:02.000Z",
                        sidechain: Bool = false, messageId: String = "msg_T") -> String {
        var o = base("assistant", session: session, cwd: cwd, branch: "feat/#52/x", ts: ts, sidechain: sidechain)
        o["message"] = ["id": messageId, "model": "claude-opus-5-5", "role": "assistant",
                        "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
                        "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 1000,
                                  "cache_creation_input_tokens": 5]]
        return json(o)
    }

    static func toolResult(_ id: String, isError: Bool = false, content: String = "ok", denied: Bool = false,
                           session: String = "s1", ts: String = "2026-10-10T01:00:03.000Z", sidechain: Bool = false) -> String {
        var o = base("user", session: session, cwd: "/r/ios", branch: "feat/#52/x", ts: ts, sidechain: sidechain)
        o["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                     "is_error": isError, "content": content]]]
        o["toolUseResult"] = ["stdout": content]
        if denied { o["toolDenialKind"] = "user-rejected" }
        return json(o)
    }

    static func text(_ t: String, session: String = "s1", ts: String = "2026-10-10T01:00:04.000Z",
                     messageId: String = "msg_A", sidechain: Bool = false) -> String {
        var o = base("assistant", session: session, cwd: "/r/ios", branch: "feat/#52/x", ts: ts, sidechain: sidechain)
        o["message"] = ["id": messageId, "model": "claude-opus-5-5", "role": "assistant",
                        "content": [["type": "text", "text": t]],
                        "usage": ["input_tokens": 2, "output_tokens": 30, "cache_read_input_tokens": 500,
                                  "cache_creation_input_tokens": 8]]
        return json(o)
    }

    static func duration(_ ms: Int) -> String {
        var o = base("system", session: "s1", cwd: "/r/ios", branch: "feat/#52/x", ts: "2026-10-10T01:00:05.000Z")
        o["subtype"] = "turn_duration"
        o["durationMs"] = ms
        return json(o)
    }

    static func interrupted() -> String {
        var o = base("user", session: "s1", cwd: "/r/ios", branch: "feat/#52/x", ts: "2026-10-10T01:00:06.000Z")
        o["message"] = ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user]"]]]
        o["interruptedMessageId"] = "msg_X"
        return json(o)
    }

    static func compact() -> String {
        var o = base("user", session: "s1", cwd: "/r/ios", branch: "feat/#52/x", ts: "2026-10-10T01:00:07.000Z")
        o["message"] = ["role": "user", "content": "This session is being continued from a previous conversation"]
        o["isCompactSummary"] = true
        return json(o)
    }
}
