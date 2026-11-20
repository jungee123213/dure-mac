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

    /// 조율자의 둘째 PermissionRequest 그룹 — 상승 요청을 창 없이 거절한다. 입력은 읽어 버린다(파이프가 막히지 않게).
    /// 실측 그대로의 문자열이다 — 모델이 받는 것은 `Rejected("PermissionRequest hook denied approval")`(i-stage3 (e)).
    static let orchestratorDenyCommand =
        #"cat >/dev/null; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'"#

    /// 게이트를 돌리지 못했을 때(실행 파일 없음 127 · 신호로 죽음 · 그 밖의 종료 코드) 모델이 받는 이유. 마침표로 끝내지 않는다 —
    /// Codex 가 뒤에 `. Command:` 를 붙인다.
    static let gateLaunchFailure = "두레 게이트: 게이트를 실행하지 못했다"

    /// 게이트 훅 명령 — `<두레 실행 파일> --dure-codex-gate` 를 감싸 **닫힌 채 실패**하게 한다.
    /// Codex 는 exit 2 + 비지 않은 stderr 만 막고 나머지(127 · 신호 · exit 1)는 통과시킨다(i-stage3 (d)).
    /// 그래서 0 · 2 는 그대로 내고, 그 밖의 종료는 이유를 stderr 에 써서 exit 2 로 바꾼다. 경로는 한 단어로 인용한다.
    ///
    /// Codex 는 훅 명령을 사용자 계정 셸로 돌린다(실측: `/bin/zsh -c '<명령>'`, `$SHELL` 환경 변수는 안 따른다).
    /// 감싼 부분은 POSIX 문법이라 fish 같은 셸에서는 문법 오류(→ 통과)가 된다 — 그래서 바깥은 `/bin/sh -c '<안>'`
    /// 단순 명령 하나로 내고 안쪽은 언제나 `/bin/sh` 가 읽는다. 신뢰 해시는 이 본문 그대로 걸린다.
    static func gateCommand(executable: String) -> String {
        "/bin/sh -c " + Spawn.quoted(gateScript(executable: executable))
    }

    /// `/bin/sh` 가 읽는 안쪽 — 게이트를 돌리고 0 · 2 가 아닌 종료를 이유 + exit 2 로 바꾼다.
    static func gateScript(executable: String) -> String {
        Spawn.quoted(executable) + " " + CodexGateMain.flag
            + "; s=$?; [ \"$s\" -eq 0 ] && exit 0; [ \"$s\" -eq 2 ] && exit 2; "
            + "printf '%s\\n' \"\(gateLaunchFailure) (종료 코드 $s)\" >&2; exit 2"
    }

    /// 두레가 세션에 얹는 훅. shim(상태 · 알림)은 SessionStart · UserPromptSubmit · PostToolUse · Stop 은 두 프로필 모두,
    /// PermissionRequest 는 레포 페인만.
    /// - 레포 페인: + PreToolUse 게이트(matcher 없음 — `tool_name` 은 게이트가 스스로 본다, timeout 10).
    ///   `gateExecutable` 이 nil 이면 게이트가 빠진다 — **레포 페인은 그 전에 시작을 멈춰야 한다**(`CodexPaneRuntime` 이 닫힌 채 실패).
    /// - 조율자: PermissionRequest 는 **거절 그룹 하나뿐**(timeout 5, 신뢰 키 `permission_request:0:0`). shim 을 같이 걸면
    ///   상태가 "승인 대기" 로 가고 알림이 뜨는데, 그 요청은 거절 그룹이 바로 닫아 답할 창이 없다 — 상승 시도마다 거짓 알림이 된다(D-11).
    ///   조율자의 "승인 대기 + 알림" 은 없다(레포 페인만).
    static func dureGroups(shimPath: String, profile: CodexProfile, gateExecutable: String?) -> [Group] {
        func shim(_ event: String) -> Group {
            Group(event: event, matcher: nil, command: Spawn.quoted(shimPath) + " " + event, timeout: 5)
        }
        switch profile {
        case .repoPane:
            var groups = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"].map(shim)
            if let gateExecutable {
                groups.append(Group(event: "PreToolUse", matcher: nil,
                                    command: gateCommand(executable: gateExecutable), timeout: 10))
            }
            return groups
        case .orchestrator:
            return [shim("SessionStart"), shim("UserPromptSubmit"),
                    Group(event: "PermissionRequest", matcher: nil, command: orchestratorDenyCommand, timeout: 5),
                    shim("PostToolUse"), shim("Stop")]
        }
    }
}
