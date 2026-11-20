import Testing
@testable import Dure

struct CodexHooksTests {
    @Test func 사용자_전역_훅의_신뢰_해시를_재현한다() {
        let g = CodexHooks.Group(event: "SessionStart", matcher: "*",
            command: #"node "/Users/qhrtj07/.claude/scripts/gptaku-update-check.cjs""#, timeout: 5)
        #expect(CodexHooks.trustHash(g) == "sha256:5064ac3e2883b8f01b2d389632f4d2c955bcdc915562897ffb99927e8b208ee0")
    }
    @Test func matcher_없는_훅의_해시() {
        let g = CodexHooks.Group(event: "Stop", matcher: nil,
            command: "/Users/qhrtj07/.claude/skills/gstack/hosts/claude/hooks/timeline-stop-hook", timeout: 5)
        #expect(CodexHooks.trustHash(g) == "sha256:43864f118fe4d0aa73736ef8982048b5a26c0d90ac35af5458ad8ffcedfbca7b")
    }
    @Test func 작은따옴표로_감싼_shim_경로의_해시() {
        let g = CodexHooks.Group(event: "SessionStart", matcher: nil, command: "'/Users/x/.dure/bin/hook' SessionStart", timeout: 5)
        #expect(CodexHooks.trustHash(g) == "sha256:4a115e5d487826fd035544b90d7c549eca48215f025c668cea508b44e72815ce")
    }
    @Test func 신뢰_표는_인라인_하나이고_키가_세션_플래그_모양이다() {
        let args = CodexHooks.configArguments(CodexHooks.dureGroups(shimPath: "/Users/x/.dure/bin/hook"))
        let states = args.filter { $0.hasPrefix("hooks.state=") }
        #expect(states.count == 1)
        #expect(states[0].contains(#""/<session-flags>/config.toml:session_start:0:0"={trusted_hash="sha256:"#))
        #expect(args.contains { $0.hasPrefix("hooks.PermissionRequest=[") })
        #expect(!args.contains { $0.contains("hooks.state.") })
    }
    @Test func 같은_이벤트의_두_번째_그룹은_번호_1이다() {
        let gs = [
            CodexHooks.Group(event: "SessionStart", matcher: nil, command: "a", timeout: 5),
            CodexHooks.Group(event: "SessionStart", matcher: nil, command: "b", timeout: 5),
        ]
        let args = CodexHooks.configArguments(gs)
        let state = args.first { $0.hasPrefix("hooks.state=") }!
        #expect(state.contains(#""/<session-flags>/config.toml:session_start:0:0""#))
        #expect(state.contains(#""/<session-flags>/config.toml:session_start:1:0""#))
        #expect(args.filter { $0.hasPrefix("hooks.SessionStart=") }.count == 1)
    }
    @Test func command_의_큰따옴표와_역슬래시를_TOML_에서_이스케이프한다() {
        let g = CodexHooks.Group(event: "SessionStart", matcher: "*", command: #"node "/a b""#, timeout: 5)
        let args = CodexHooks.configArguments([g])
        #expect(args[1] == #"hooks.SessionStart=[{hooks=[{type="command",command="node \"/a b\"",timeout=5}],matcher="*"}]"#)
        let b = CodexHooks.Group(event: "Stop", matcher: nil, command: #"a\b"#, timeout: 5)
        #expect(CodexHooks.configArguments([b])[1].contains(#"command="a\\b""#))
    }
    @Test func 한글_경로는_UTF8_그대로_해시한다() {
        let g = CodexHooks.Group(event: "Stop", matcher: nil, command: "'/Users/한글/.dure/bin/hook' Stop", timeout: 5)
        #expect(CodexHooks.trustHash(g) == "sha256:c8c2965c81d5761276e3182ed05700915b60cbe4194b44026ed4c091c51da384")
    }
    @Test func matcher_를_무시하는_이벤트는_해시에서_뺀다() {
        let a = CodexHooks.Group(event: "Stop", matcher: "한", command: "x", timeout: 5)
        let b = CodexHooks.Group(event: "Stop", matcher: nil, command: "x", timeout: 5)
        #expect(CodexHooks.trustHash(a) == CodexHooks.trustHash(b))
        #expect(!CodexHooks.configArguments([a])[1].contains("matcher"))
    }
    @Test func 제어문자는_짧은_꼴로_이스케이프하고_슬래시는_그대로_해시한다() {
        // spike M11: python json.dumps(ensure_ascii=False) 로 계산한 값
        let g = CodexHooks.Group(event: "PreToolUse", matcher: "^Bash|한$",
            command: "/tmp/x.sh \t탭 😀 \u{7f} \"q\" \\b", timeout: 5)
        #expect(CodexHooks.trustHash(g) == "sha256:43eea80ea58d941b0316f91b90ba50d5a93d892c457140f3493bcd3eeeb80003")
    }
    @Test func snake_이름() {
        #expect(CodexHooks.snakeName("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexHooks.snakeName("Stop") == "stop")
    }
}
