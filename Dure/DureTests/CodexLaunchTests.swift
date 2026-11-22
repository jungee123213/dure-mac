import Testing
import Foundation
@testable import Dure

struct CodexLaunchTests {

    private func server(plugins: [String] = []) -> String {
        CodexLaunch.serverScript(cwd: "/r/a b", sessionID: "abcd1234", home: "/h/codex-home/abcd1234",
                                 socket: "/s/abcd1234.sock", hookArguments: ["-c", "hooks.X=[]"],
                                 disabledPlugins: plugins)
    }

    private func tui(profile: CodexProfile = .repoPane, prompt: String? = nil) -> String {
        CodexLaunch.tuiScript(cwd: "/r/a b", sessionID: "abcd1234", socket: "/s/abcd1234.sock",
                              failMarker: "/s/abcd1234.fail", log: "/s/abcd1234.log",
                              profile: profile, initialPrompt: prompt)
    }

    @Test func 서버_스크립트는_페인_home_과_세션을_서버에_준다() {
        let s = server()
        #expect(s.contains("export DURE_SESSION='abcd1234'"))
        #expect(s.contains("export DURE_AGENT_KIND='codex'"))
        #expect(s.contains("export CODEX_HOME='/h/codex-home/abcd1234'"))
        #expect(s.contains("exec codex app-server --listen 'unix:///s/abcd1234.sock'"))
    }

    @Test func 서버_스크립트는_cd_와_exec_를_and_로_잇는다() {
        #expect(server().contains("cd '/r/a b' && exec codex"))
    }

    @Test func 서버는_앱_커넥터를_끄고_CLAUDE_md_를_대체로_읽는다() {
        let s = server()
        #expect(s.contains("-c 'check_for_update_on_startup=false'"))
        #expect(s.contains("-c 'project_doc_fallback_filenames=[\"CLAUDE.md\"]'"))
        #expect(s.contains("-c 'features.apps=false'"))
        #expect(s.contains("'hooks.X=[]'"))
    }

    @Test func 꺼야_할_플러그인마다_enabled_false_를_준다() {
        let s = server(plugins: ["understand-anything@understand-anything", "b@c"])
        #expect(s.contains("-c 'plugins.understand-anything@understand-anything.enabled=false'"))
        #expect(s.contains("-c 'plugins.b@c.enabled=false'"))
    }

    @Test func 게이트와_거절_훅_인자는_서버_스크립트의_셸_인용을_거쳐도_그대로다() throws {
        // 거절 명령에는 작은따옴표가, 게이트 경로에는 공백이 있다 — 실제 셸로 풀어 codex 가 받을 argv 를 본다.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane,
                                           gateExecutable: "/Applications/My Apps/Dure.app/Contents/MacOS/Dure")
            + CodexHooks.dureGroups(shimPath: "/x/hook", profile: .orchestrator, gateExecutable: nil)
                .filter { $0.command.contains("hookSpecificOutput") }
        let hookArgs = CodexHooks.configArguments(groups)
        let script = CodexLaunch.serverScript(cwd: dir.path, sessionID: "abcd1234", home: "/h", socket: "/s/x.sock",
                                              hookArguments: hookArgs, disabledPlugins: [])
        let probe = script.replacingOccurrences(of: "exec codex ", with: "exec /usr/bin/printf '%s\\0' ")
        #expect(probe != script)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", probe]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let argv = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        for value in stride(from: 1, to: hookArgs.count, by: 2).map({ hookArgs[$0] }) {
            #expect(argv.contains(value))
        }
        let pre = try #require(argv.first { $0.hasPrefix("hooks.PreToolUse=") })
        let gate = CodexHooks.gateCommand(executable: "/Applications/My Apps/Dure.app/Contents/MacOS/Dure")
        #expect(pre.contains("command=" + CodexHooks.tomlString(gate) + ","))
        let perm = try #require(argv.first { $0.hasPrefix("hooks.PermissionRequest=") })
        #expect(perm.contains(#"printf '%s' '{\"hookSpecificOutput\""#))
    }

    @Test func TUI_는_remote_와_C_와_샌드박스를_준다() {
        let r = tui(profile: .repoPane)
        #expect(r.contains("exec codex --remote 'unix:///s/abcd1234.sock' -C '/r/a b' -s 'workspace-write' -a 'on-request'"))
        let o = tui(profile: .orchestrator)
        #expect(o.contains("-s 'read-only' -a 'on-request'"))
        #expect(!r.contains("--add-dir") && !o.contains("--add-dir"))
        #expect(r.contains("export DURE_SESSION='abcd1234'"))
        #expect(r.contains("export DURE_AGENT_KIND='codex'"))
    }

    @Test func TUI_는_소켓을_기다리고_실패_표식을_읽는다() {
        let s = tui()
        #expect(s.contains("'/s/abcd1234.sock'"))
        #expect(s.contains("'/s/abcd1234.fail'"))
        #expect(s.contains("-S "))
        #expect(s.contains("sleep 0.1"))
        #expect(s.contains("[ $i -lt \(CodexLaunch.tuiWaitSeconds * 10) ]"))
        #expect(s.contains("Codex 서버가 \(CodexLaunch.tuiWaitSeconds)초 안에 뜨지 않았습니다 — 로그: /s/abcd1234.log"))
        #expect(!s.contains("10초 안에"))
        #expect(s.contains("cd '/r/a b' && "))
        #expect(s.contains("exit 1"))
    }

    /// 10초 판정은 런타임 몫이다(서버를 띄운 때부터). TUI 의 상한은 런타임이 판정을 내리기까지의 최악 시간보다 길어야
    /// 멀쩡한 서버를 두고 페인이 먼저 죽지 않는다 — 버전 확인(시간 초과 + 유예 + 정리) · 훅 목록(+ 서버 정리) · 소켓 대기를 다 더한 값.
    @Test func TUI_대기_상한은_런타임이_판정하기까지의_최악_시간보다_길다() {
        let version = CodexPaneRuntime.versionTimeout + LiveCommandRunner().grace + 5 + 1
        let inventory = CodexHookInventory.timeout + CodexHookInventory.shutdownBudget
        let worst = version + inventory + CodexPaneRuntime.defaultSocketTimeout
        #expect(TimeInterval(CodexLaunch.tuiWaitSeconds) > worst)
        #expect(CodexPaneRuntime.defaultSocketTimeout == 10)
    }

    @Test func 첫_프롬프트는_대시_대시_뒤에_인용된다() {
        #expect(tui(prompt: "it's").contains(" -- 'it'\\''s'"))
    }

    @Test func 공백뿐인_첫_프롬프트는_넘기지_않는다() {
        #expect(!tui(prompt: "  \n ").contains(" -- "))
        #expect(!tui(prompt: nil).contains(" -- "))
    }

    @Test func 버전_판정() {
        #expect(CodexLaunch.isSupported(versionOutput: "codex-cli 0.167.0"))
        #expect(!CodexLaunch.isSupported(versionOutput: "codex-cli 0.166.9"))
        #expect(CodexLaunch.isSupported(versionOutput: "codex-cli 0.170.1"))
        #expect(CodexLaunch.isSupported(versionOutput: "codex-cli 1.0.0"))
        #expect(!CodexLaunch.isSupported(versionOutput: ""))
        #expect(!CodexLaunch.isSupported(versionOutput: "garbage"))
    }

    @Test func 경로는_세션별로_루트_아래다() {
        let root = URL(fileURLWithPath: "/x")
        #expect(CodexLaunch.socketPath(forSession: "ab", root: root) == "/x/ab.sock")
        #expect(CodexLaunch.failMarkerPath(forSession: "ab", root: root) == "/x/ab.fail")
        #expect(CodexLaunch.logPath(forSession: "ab", root: root) == "/x/ab.log")
        #expect(CodexLaunch.defaultRoot.path.hasSuffix("/.dure/codex"))
    }

    @Test func 소켓_경로는_104바이트_미만이다() {
        let path = NSHomeDirectory() + "/.dure/codex/abcd1234.sock"
        #expect(path.utf8.count < 104)
        #expect(CodexLaunch.socketPath(forSession: "abcd1234").utf8.count < 104)
    }
}

struct CodexLaunchMCPTests {
    private func server(_ mcp: String?) -> String {
        CodexLaunch.serverScript(cwd: "/r", sessionID: "abcd1234", home: "/h", socket: "/s/a.sock",
                                 hookArguments: [], disabledPlugins: [], mcpSocket: mcp)
    }

    @Test func 서버는_두레_MCP_를_nc_다리로_승인_없이_붙인다() {
        let s = server("/s/m.sock")
        #expect(s.contains("'mcp_servers.dure.command=\"/usr/bin/nc\"'"))
        #expect(s.contains("'mcp_servers.dure.args=[\"-U\",\"/s/m.sock\"]'"))
        #expect(s.contains("'mcp_servers.dure.default_tools_approval_mode=\"approve\"'"))
    }

    @Test func MCP_소켓이_없으면_MCP_인자도_없다() {
        #expect(!server(nil).contains("mcp_servers"))
    }

    @Test func MCP_소켓_경로의_따옴표와_역슬래시는_TOML_로_이스케이프된다() {
        let s = server("/s/a\"b\\c.sock")
        #expect(s.contains(#"args=["-U","/s/a\"b\\c.sock"]"#))
    }
}

/// 이슈 #56 — 두레가 어떻게 끝나든 서버가 따라 끝나게 하는 감시 셸. 실제 `/bin/zsh` 로 돌린다(`.zshrc` 를 안 읽게 안쪽은 `-c`).
struct CodexServerWatchdogTests {

    @Test func 감시_셸은_파이프를_fd3_으로_옮기고_안쪽_셸은_stdin_을_비운다() {
        let args = CodexLaunch.watchdogArguments(script: "exec codex app-server")
        #expect(args == ["-c", CodexLaunch.serverWatchdog, "zsh", "-ilc", "exec codex app-server"])
        let w = CodexLaunch.serverWatchdog
        #expect(w.hasPrefix("exec 3<&0 </dev/null"))
        #expect(w.contains("read -r -u 3"))
        #expect(w.contains("kill -TERM"))
        #expect(w.contains("kill -KILL"))
        #expect(w.contains("wait $srv"))
    }

    private struct Run {
        let process: Process
        let lifeline: FileHandle
    }

    private func start(_ script: String) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = CodexLaunch.watchdogArguments(script: script, innerFlags: "-c")
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return Run(process: p, lifeline: pipe.fileHandleForWriting)
    }

    private func waitExit(_ p: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }

    private func children(of pid: pid_t, within seconds: TimeInterval = 3) -> [pid_t] {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let found = LiveCommandRunner.descendants(of: pid)
            if !found.isEmpty { return found }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return []
    }

    @Test func 파이프가_닫히면_서버_트리를_끈다() throws {
        // 서버 흉내: 자식 하나를 두고 오래 산다(code-mode-host 처럼).
        let r = try start("sleep 30 & exec sleep 31")
        let tree = children(of: r.process.processIdentifier)
        #expect(!tree.isEmpty)
        try r.lifeline.close()
        #expect(waitExit(r.process, within: 6))
        Thread.sleep(forTimeInterval: 0.2)
        for pid in tree { #expect(kill(pid, 0) != 0, "남은 pid \(pid)") }
    }

    @Test func 서버가_먼저_끝나면_그_종료_코드로_끝난다() throws {
        let r = try start("exit 7")
        #expect(waitExit(r.process, within: 5))
        #expect(r.process.terminationStatus == 7)
        try? r.lifeline.close()
    }

    @Test func 안쪽_셸의_stdin_은_파이프가_아니다() throws {
        // stdin 이 파이프면 read 는 5초를 다 기다린다(쓰는 끝이 열려 있으므로). /dev/null 이면 바로 EOF.
        let started = Date()
        let r = try start("read -t 5 x; exit 3")
        #expect(waitExit(r.process, within: 6))
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(r.process.terminationStatus == 3)
        try? r.lifeline.close()
    }
}

struct CodexLifelineTests {
    @Test func 생명줄은_두_번_닫아도_한_번만_닫는다() throws {
        let pipe = Pipe()
        let line = CodexLifeline(pipe.fileHandleForWriting)
        line.close()
        line.close()
        // 쓰는 끝이 닫혔으면 읽는 쪽은 바로 EOF.
        #expect(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
