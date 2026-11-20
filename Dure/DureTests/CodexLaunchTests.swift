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
