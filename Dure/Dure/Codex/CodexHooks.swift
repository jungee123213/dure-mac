import Foundation
import CryptoKit

/// Codex 세션 훅을 `-c hooks.<Event>=[…]` 인자로 만들고, 신뢰 표(`hooks.state`)를 함께 낸다.
/// 신뢰 표가 없으면 Codex 는 훅을 조용히 건너뛴다. 해시 규칙은 docs/spikes/2026-11-19-codex/f-stage1.md M11.
nonisolated enum CodexHooks {

    struct Group: Equatable {
        let event: String      // PascalCase (`SessionStart`)
        let matcher: String?
        let command: String
        let timeout: Int
    }

    /// matcher 를 해시 · TOML 에 넣는 이벤트. 나머지는 matcher 를 버린다(Stop 의 matcher 는 hooks/list 에서 null).
    static let matcherEvents: Set<String> = ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest"]

    static func snakeName(_ event: String) -> String {
        var out = ""
        for (i, ch) in event.enumerated() {
            if ch.isUppercase {
                if i > 0 { out += "_" }
                out += ch.lowercased()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func effectiveMatcher(_ g: Group) -> String? {
        matcherEvents.contains(g.event) ? g.matcher : nil
    }

    /// Codex 가 timeout 을 줄여 쓰는 이벤트(초). 해시도 줄인 값으로 계산하므로 내보낼 때도 같은 값이어야 한다.
    static let timeoutCaps: [String: Int] = ["SessionEnd": 3, "Interrupt": 3]

    static func effectiveTimeout(_ g: Group) -> Int {
        guard let cap = timeoutCaps[g.event] else { return g.timeout }
        return min(g.timeout, cap)
    }

    /// `hooks.state` 항목 하나 — 세션 플래그 밖(페인 home 의 config 사본)에서 온 훅의 신뢰.
    struct TrustState: Equatable {
        let key: String
        let hash: String
    }

    /// 정규 JSON 문자열 값 — `"` `\` 와 U+0000~001F 만 이스케이프. 비 ASCII · `/` 는 그대로.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    static func trustHash(_ g: Group) -> String {
        // 키 정렬: event_name < hooks < matcher, 안쪽은 async < command < timeout < type
        var json = "{\"event_name\":" + jsonString(snakeName(g.event))
        json += ",\"hooks\":[{\"async\":false,\"command\":" + jsonString(g.command)
        json += ",\"timeout\":\(effectiveTimeout(g)),\"type\":\"command\"}]"
        if let m = effectiveMatcher(g) { json += ",\"matcher\":" + jsonString(m) }
        json += "}"
        let digest = SHA256.hash(data: Data(json.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// TOML 기본 문자열 — `"` `\` 와 제어 문자를 이스케이프한다.
    static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7f {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// `extraTrust` 는 같은 인라인 표 하나에 덧붙인다 — `hooks.state` 는 `-c` 하나로만 낸다.
    static func configArguments(_ groups: [Group], extraTrust: [TrustState] = []) -> [String] {
        var order: [String] = []
        var byEvent: [String: [Group]] = [:]
        for g in groups {
            if byEvent[g.event] == nil { order.append(g.event) }
            byEvent[g.event, default: []].append(g)
        }
        var args: [String] = []
        var states: [String] = []
        for event in order {
            let gs = byEvent[event] ?? []
            var tables: [String] = []
            for (idx, g) in gs.enumerated() {
                var t = "{hooks=[{type=\"command\",command=\(tomlString(g.command)),timeout=\(effectiveTimeout(g))}]"
                if let m = effectiveMatcher(g) { t += ",matcher=\(tomlString(m))" }
                t += "}"
                tables.append(t)
                let key = "/<session-flags>/config.toml:\(snakeName(event)):\(idx):0"
                states.append("\(tomlString(key))={trusted_hash=\(tomlString(trustHash(g)))}")
            }
            args += ["-c", "hooks.\(event)=[" + tables.joined(separator: ",") + "]"]
        }
        for t in extraTrust {
            states.append("\(tomlString(t.key))={trusted_hash=\(tomlString(t.hash))}")
        }
        args += ["-c", "hooks.state={" + states.joined(separator: ",") + "}"]
        return args
    }

    static func dureGroups(shimPath: String) -> [Group] {
        ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"].map {
            Group(event: $0, matcher: nil, command: Spawn.quoted(shimPath) + " " + $0, timeout: 5)
        }
    }
}
