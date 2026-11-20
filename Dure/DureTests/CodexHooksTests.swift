import Testing
import Foundation
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
        let args = CodexHooks.configArguments(CodexHooks.dureGroups(shimPath: "/Users/x/.dure/bin/hook", profile: .repoPane,
                                                                     gateExecutable: "/A/Dure"))
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
    @Test func SessionEnd_와_Interrupt_의_timeout_은_3초로_줄여_해시하고_낸다() {
        let long = CodexHooks.Group(event: "SessionEnd", matcher: nil, command: "x", timeout: 10)
        let three = CodexHooks.Group(event: "SessionEnd", matcher: nil, command: "x", timeout: 3)
        #expect(CodexHooks.trustHash(long) == CodexHooks.trustHash(three))
        #expect(CodexHooks.configArguments([long])[1].contains("timeout=3}"))
        let i = CodexHooks.Group(event: "Interrupt", matcher: nil, command: "x", timeout: 30)
        #expect(CodexHooks.effectiveTimeout(i) == 3)
        #expect(CodexHooks.configArguments([i])[1].contains("timeout=3}"))
        // 짧은 값은 그대로, 다른 이벤트는 줄이지 않는다
        #expect(CodexHooks.effectiveTimeout(.init(event: "SessionEnd", matcher: nil, command: "x", timeout: 2)) == 2)
        let stop = CodexHooks.Group(event: "Stop", matcher: nil, command: "x", timeout: 10)
        #expect(CodexHooks.configArguments([stop])[1].contains("timeout=10}"))
    }
    @Test func config_사본_훅의_신뢰는_같은_인라인_표에_덧붙는다() {
        let extra = [CodexHooks.TrustState(key: "/h/repo-1/config.toml:session_start:0:0", hash: "sha256:ab")]
        let args = CodexHooks.configArguments(CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane,
                                                                     gateExecutable: "/A/Dure"),
                                              extraTrust: extra)
        let states = args.filter { $0.hasPrefix("hooks.state=") }
        #expect(states.count == 1)
        #expect(states[0].contains(#""/<session-flags>/config.toml:stop:0:0"={trusted_hash="sha256:"#))
        #expect(states[0].hasSuffix(#","/h/repo-1/config.toml:session_start:0:0"={trusted_hash="sha256:ab"}}"#))
    }
    // MARK: - 게이트 · 조율자 거절 (Task 4)

    private let shimEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"]

    private func state(_ args: [String]) -> String { args.first { $0.hasPrefix("hooks.state=") } ?? "" }

    @Test func 레포_페인_훅에_게이트가_있고_조율자에는_없다() {
        let repo = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane, gateExecutable: "/A/Dure")
        // shim 다섯 개는 그대로
        #expect(Array(repo.prefix(5)).map(\.event) == shimEvents)
        #expect(repo.prefix(5).allSatisfy { $0.command == "'/x/hook' \($0.event)" && $0.timeout == 5 })
        let gates = repo.filter { $0.event == "PreToolUse" }
        #expect(gates.count == 1)
        let gate = gates[0]
        #expect(gate.command == CodexHooks.gateCommand(executable: "/A/Dure"))
        // 바깥은 어느 셸에서도 단순 명령 하나 — 안쪽(POSIX)은 /bin/sh 가 읽는다
        #expect(gate.command.hasPrefix(#"/bin/sh -c '"/A/Dure" --dure-codex-gate; s=$?; "#))
        #expect(gate.matcher == nil)          // tool_name 은 게이트가 스스로 본다
        #expect(gate.timeout == 10)
        #expect(!repo.contains { $0.command.contains("hookSpecificOutput") })

        let orch = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .orchestrator, gateExecutable: "/A/Dure")
        #expect(!orch.contains { $0.event == "PreToolUse" })
        #expect(!orch.contains { $0.command.contains(CodexGateMain.flag) })

        // 신뢰 표에 게이트 해시가 들어간다(없으면 Codex 가 조용히 건너뛴다)
        let args = CodexHooks.configArguments(repo)
        #expect(args.contains("hooks.PreToolUse=[{hooks=[{type=\"command\",command=\(CodexHooks.tomlString(gate.command)),timeout=10}]}]"))
        #expect(state(args).contains(#""/<session-flags>/config.toml:pre_tool_use:0:0"={trusted_hash="\#(CodexHooks.trustHash(gate))"}"#))
    }

    @Test func 조율자_훅에_권한_요청_거절이_있다() throws {
        let orch = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .orchestrator, gateExecutable: nil)
        // shim 은 PermissionRequest 를 뺀 네 이벤트 — 거절이 닫는 요청에 "승인 대기" 알림을 띄우지 않는다(D-11)
        #expect(orch.filter { $0.command.hasPrefix("'/x/hook' ") }.map(\.event)
                == ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop"])
        #expect(!orch.contains { $0.command == "'/x/hook' PermissionRequest" })
        let pr = orch.filter { $0.event == "PermissionRequest" }
        #expect(pr.count == 1)
        let deny = try #require(pr.first)
        #expect(deny.command == #"cat >/dev/null; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'"#)
        #expect(deny.matcher == nil)
        #expect(deny.timeout == 5)

        let args = CodexHooks.configArguments(orch)
        let table = try #require(args.first { $0.hasPrefix("hooks.PermissionRequest=[") })
        #expect(table == "hooks.PermissionRequest=[{hooks=[{type=\"command\",command=\(CodexHooks.tomlString(deny.command)),timeout=5}]}]")
        #expect(state(args).contains(#""/<session-flags>/config.toml:permission_request:0:0"={trusted_hash="\#(CodexHooks.trustHash(deny))"}"#))
        #expect(!state(args).contains("permission_request:1:0"))
        // 레포 페인은 그대로 — shim PermissionRequest(승인 대기 + 알림)만, 거절 없음
        let repo = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane, gateExecutable: "/A/Dure")
        #expect(repo.filter { $0.event == "PermissionRequest" }.map(\.command) == ["'/x/hook' PermissionRequest"])
        #expect(!repo.contains { $0.command.contains("hookSpecificOutput") })
    }

    @Test func 실행_파일_경로에_공백이_있어도_한_명령이다() {
        let exe = "/Applications/My Apps/Dure.app/Contents/MacOS/Dure"
        let repo = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane, gateExecutable: exe)
        let gate = repo.first { $0.event == "PreToolUse" }
        #expect(gate?.command.hasPrefix(#"/bin/sh -c '"/Applications/My Apps/Dure.app/Contents/MacOS/Dure" --dure-codex-gate; "#) == true)
        // 작은따옴표가 든 경로도 한 단어로 묶인다 — 실제 셸 실행은 아래 테스트가 본다(폴더 이름에 ' 와 공백)
        let odd = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane, gateExecutable: "/A/it's/Dure")
        #expect(odd.first { $0.event == "PreToolUse" }?.command
                == "/bin/sh -c '" + CodexHooks.gateScript(executable: "/A/it's/Dure") + "'")
        #expect(CodexHooks.gateScript(executable: "/A/it's/Dure").hasPrefix(#""/A/it$(printf \\047)s/Dure" --dure-codex-gate; s=$?; "#))
    }

    /// 최종 리뷰 2 — 안쪽에 작은따옴표가 있으면 바깥이 `'\''` 꼴이 되고, 그 꼴을 모르는 계정 셸(nushell 등)에서 문법 오류 → 통과다.
    @Test(arguments: ["/A/Dure", "/Applications/My Apps/Dure.app/Contents/MacOS/Dure", "/A/it's/Dure", #"/A/"q"/$HOME/`x`/b\s/Dure"#,
                      "/A/줄\n바꿈/Dure"])
    func 게이트_안쪽에는_작은따옴표가_없다(_ exe: String) {
        let script = CodexHooks.gateScript(executable: exe)
        #expect(!script.contains("'"), "\(script)")
        let command = CodexHooks.gateCommand(executable: exe)
        #expect(command == "/bin/sh -c '" + script + "'")
        #expect(command.filter { $0 == "'" }.count == 2)
        #expect(command == "/bin/sh -c " + Spawn.quoted(script))   // 작은따옴표가 없으니 Spawn.quoted 와 같은 꼴
    }

    @Test func 큰따옴표_인용은_sh_가_원래_글자로_읽는다() throws {
        for s in ["/A/it's/Dure", #"/A/"q"/$HOME/`x`/b\s/Dure"#, "/A/줄\n바꿈/Dure", "a'b'c", "''", ""] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s " + CodexHooks.shDoubleQuoted(s)]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(String(decoding: data, as: UTF8.self) == s, "\(s)")
        }
    }

    /// 감싼 게이트 명령을 실제 셸로 돌린다 — stdin 은 게이트로 그대로 간다.
    /// stdin 은 파일로 준다 — 파이프에 쓰면 게이트가 읽지 않고 끝난 경우 SIGPIPE 가 테스트 호스트로 온다.
    private func runGate(_ command: String, shell: String, stdin: URL) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", command]
        let err = Pipe()
        let input = try FileHandle(forReadingFrom: stdin)
        defer { try? input.close() }
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: e, as: UTF8.self))
    }

    @Test func 게이트를_실행하지_못하면_감싼_명령이_exit_2_와_이유로_막는다() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString.prefix(8)) it's 공백")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func stub(_ name: String, _ body: String, mode: Int = 0o755) throws -> String {
            let url = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url.path
        }
        // 통과: stdin 이 게이트에 그대로 가야 0
        let pass = try stub("pass", #"IN=$(cat); [ "$IN" = "PAYLOAD" ] || exit 1; exit 0"#)
        let deny = try stub("deny", "cat >/dev/null; printf '두레 게이트: 막음' >&2; exit 2")
        let one = try stub("one", "cat >/dev/null; exit 1")
        let crash = try stub("crash", "cat >/dev/null; kill -SEGV $$")
        let noexec = try stub("noexec", "exit 0", mode: 0o644)
        let missing = dir.appendingPathComponent("없음/Dure").path
        let payload = dir.appendingPathComponent("payload")
        try "PAYLOAD".write(to: payload, atomically: true, encoding: .utf8)

        for shell in ["/bin/sh", "/bin/zsh", "/bin/bash"] {
            let ok = try runGate(CodexHooks.gateCommand(executable: pass), shell: shell, stdin: payload)
            #expect(ok.status == 0 && ok.stderr.isEmpty, "\(shell) pass")
            let d = try runGate(CodexHooks.gateCommand(executable: deny), shell: shell, stdin: payload)
            #expect(d.status == 2 && d.stderr == "두레 게이트: 막음", "\(shell) deny")
            for (exe, code) in [(one, "1"), (crash, "139"), (noexec, "126"), (missing, "127")] {
                let r = try runGate(CodexHooks.gateCommand(executable: exe), shell: shell, stdin: payload)
                #expect(r.status == 2, "\(shell) \(exe)")
                let last = r.stderr.split(separator: "\n").last.map(String.init) ?? ""
                #expect(last == "\(CodexHooks.gateLaunchFailure) (종료 코드 \(code))", "\(shell) \(exe): \(r.stderr)")
                #expect(!r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("."))
            }
        }
    }

    @Test func snake_이름() {
        #expect(CodexHooks.snakeName("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexHooks.snakeName("Stop") == "stop")
    }
}
