import Foundation

/// Codex PreToolUse 훅이 부르는 게이트 실행 모드. `Dure --dure-codex-gate` — stdin 의 훅 페이로드를 읽고
/// 막을 때만 exit 2 + stderr. Codex 는 exit 2 에 비지 않은 stderr 가 있어야 막는다(빈 stderr · exit 1 · stdout 만은 통과, Task 1 실측).
/// stderr 는 마침표로 끝나지 않는다 — Codex 가 뒤에 `. Command:` 를 붙인다.
nonisolated enum CodexGateMain {
    static let flag = "--dure-codex-gate"

    private static let unreadable = "두레 게이트: 훅 입력을 읽지 못했다"

    static func respond(stdin: Data) -> (exitCode: Int32, stderr: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let tool = obj["tool_name"] as? String else {
            return (2, unreadable)
        }
        guard tool == "Bash" else { return (0, "") }
        guard let input = obj["tool_input"] as? [String: Any],
              let command = input["command"] as? String else {
            return (2, unreadable)
        }
        switch CodexGitPolicy.gateDecision(command) {
        case .pass:
            return (0, "")
        case .deny(let reason):
            var text = reason.hasPrefix("두레 게이트") ? reason : "두레 게이트: \(reason)"
            while text.hasSuffix(".") || text.hasSuffix(" ") || text.hasSuffix("\n") { text.removeLast() }
            return (2, text.isEmpty ? unreadable : text)
        }
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var data = Data()
        var failed = false
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(0, &buf, buf.count)
            if n > 0 { data.append(buf, count: n) }
            else if n == 0 { break }
            else if errno == EINTR { continue }
            else { failed = true; break }
        }
        let r = failed ? (exitCode: Int32(2), stderr: unreadable) : respond(stdin: data)
        if !r.stderr.isEmpty {
            let bytes = Array(r.stderr.utf8)
            var off = 0
            while off < bytes.count {
                let w = bytes[off...].withUnsafeBufferPointer { write(2, $0.baseAddress, $0.count) }
                if w > 0 { off += w } else if w < 0 && errno == EINTR { continue } else { break }
            }
        }
        exit(r.exitCode)
    }
}
