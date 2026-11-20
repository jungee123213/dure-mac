import Testing
import Foundation
@testable import Dure

struct CodexGateMainTests {
    private func input(_ tool: String, _ command: String) -> Data {
        let obj: [String: Any] = ["tool_name": tool, "tool_input": ["command": command]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test func Bash_가_아니면_통과한다() {
        let r = CodexGateMain.respond(stdin: Data(#"{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch"}}"#.utf8))
        #expect(r.exitCode == 0)
        #expect(r.stderr.isEmpty)
    }

    @Test func 빠져나가는_push_는_2_와_안내를_낸다() {
        let r = CodexGateMain.respond(stdin: input("Bash", "git push -u origin b --force"))
        #expect(r.exitCode == 2)
        #expect(r.stderr.contains("두레 게이트"))
        #expect(r.stderr.hasPrefix("두레 게이트: 두레 게이트") == false)
    }

    @Test func 안전한_명령은_0_이고_조용하다() {
        let r = CodexGateMain.respond(stdin: input("Bash", "git status"))
        #expect(r.exitCode == 0)
        #expect(r.stderr.isEmpty)
    }

    @Test func 막을_때는_stderr_가_비지_않고_마침표로_끝나지_않는다() {
        let cases: [Data] = [
            input("Bash", "git push -u origin b --force"),
            input("Bash", "git push \"origin"),
            Data(), Data("{".utf8),
            Data(#"{"tool_name":"Bash"}"#.utf8),
            Data(#"{"tool_name":"Bash","tool_input":{"command":3}}"#.utf8),
        ]
        for d in cases {
            let r = CodexGateMain.respond(stdin: d)
            #expect(r.exitCode == 2)
            let t = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!t.isEmpty)
            #expect(!r.stderr.hasSuffix("."))
            #expect(r.stderr.hasPrefix("두레 게이트"))
        }
    }

    @Test(arguments: [Data(), Data("{".utf8), Data("{\"tool_name\":\"Bash\"}".utf8), Data("{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":3}}".utf8)])
    func 이상한_입력은_막는다(_ d: Data) {
        #expect(CodexGateMain.respond(stdin: d).exitCode == 2)
    }

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func fuzzStrings() -> [String] {
        var g = LCG(state: 42)
        let atoms = ["git", "push", "--force", "-f", "origin", "HEAD", "main", "'", "\"", "\\", "$(", ")", "`", ";", "&&", "||", "|", ">", "<",
                     "~", "^", "{", "}", "[", "]", "*", "?", " ", "\t", "\n", "-c", "bash", "한글", "😀", "\u{0}", "\u{FFFD}", "=", "@", "-u", "--delete", ":"]
        var out: [String] = ["", " ", String(repeating: "a", count: 100_000), String(repeating: "'", count: 5000), "git " + String(repeating: "push ", count: 5000)]
        for _ in 0..<3000 {
            var s = ""
            for _ in 0..<Int.random(in: 1...25, using: &g) {
                if Int.random(in: 0..<4, using: &g) == 0 {
                    let u = UInt32.random(in: 0...0x10FFFF, using: &g)
                    s.unicodeScalars.append(Unicode.Scalar(u) ?? "\u{FFFD}")
                } else {
                    s += atoms.randomElement(using: &g)!
                }
            }
            out.append(s)
        }
        return out
    }

    @Test func 무작위_명령이_게이트를_터뜨리지_않는다() {
        for s in fuzzStrings() {
            _ = CodexGitPolicy.gateDecision(s)
            let r = CodexGateMain.respond(stdin: input("Bash", s))
            #expect(r.exitCode == 0 || r.exitCode == 2)
            if r.exitCode == 2 { #expect(!r.stderr.isEmpty && !r.stderr.hasSuffix(".")) }
        }
    }
}
