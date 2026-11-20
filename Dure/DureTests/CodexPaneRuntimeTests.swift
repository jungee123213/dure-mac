import Darwin
import Foundation
import Testing
@testable import Dure

/// Task 7 — Codex 페인 하나의 서버 수명. codex 는 돌리지 않는다: 버전 · 훅 목록 · 프로세스 · 연결은 전부 가짜,
/// 경로는 임시 폴더. 실제 `~/.codex` · `~/.dure` 를 건드리지 않는다.
@MainActor
struct CodexPaneRuntimeTests {

    // MARK: - 가짜

    final class FakeHandle: CodexProcessHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var terminateCount: Int { lock.withLock { n } }
        func terminate() { lock.withLock { n += 1 } }
    }

    final class FakeLauncher: CodexProcessLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var _scripts: [String] = []
        private var _logs: [String] = []
        private var _onExit: (@Sendable (Int32) -> Void)?
        let handle = FakeHandle()
        /// 있으면 launch 가 여기서 멈춘다 — "뜨는 도중" 을 만든다.
        let gate: DispatchSemaphore?

        init(blocking: Bool = false) { gate = blocking ? DispatchSemaphore(value: 0) : nil }

        var scripts: [String] { lock.withLock { _scripts } }
        var logs: [String] { lock.withLock { _logs } }
        func exit(_ status: Int32) { lock.withLock { _onExit }?(status) }

        func launch(script: String, logPath: String,
                    onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexProcessHandle {
            lock.withLock { _scripts.append(script); _logs.append(logPath); _onExit = onExit }
            gate?.wait()
            return handle
        }
    }

    final class FakeConnection: CodexServerConnecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [Data] = []
        private var _cancelled = 0
        private var onMessage: (@Sendable (Data) -> Void)?
        private var onClose: (@Sendable () -> Void)?

        var sent: [[String: Any]] {
            lock.withLock { _sent }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        var methods: [String] { sent.compactMap { $0["method"] as? String } }
        var cancelled: Int { lock.withLock { _cancelled } }

        func start(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
            lock.withLock { self.onMessage = onMessage; self.onClose = onClose }
        }
        func send(_ data: Data) { lock.withLock { _sent.append(data) } }
        /// 진짜 연결처럼 cancel 뒤에도 콜백이 남는다 — 늦은 메시지를 런타임이 걸러야 한다.
        func cancel() { lock.withLock { _cancelled += 1 } }
        func deliver(_ json: String) { lock.withLock { onMessage }?(Data(json.utf8)) }
    }

    // MARK: - 고정 예제

    private let fm = FileManager.default

    struct Fixture {
        let base: URL
        let user: URL
        let paths: CodexPaneRuntime.Paths
    }

    /// 소켓 경로가 104바이트를 넘지 않게 짧게.
    private func fixture() throws -> Fixture {
        let base = fm.temporaryDirectory.appendingPathComponent("cpr-\(UUID().uuidString.prefix(8))")
        let user = base.appendingPathComponent("user")
        try fm.createDirectory(at: user.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "model = \"x\"\n".write(to: user.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let run = base.appendingPathComponent("run")
        let paths = CodexPaneRuntime.Paths(home: base.appendingPathComponent("home/repo-r1"),
                                           socket: run.appendingPathComponent("abcd1234.sock").path,
                                           failMarker: run.appendingPathComponent("abcd1234.fail").path,
                                           log: run.appendingPathComponent("abcd1234.log").path)
        return Fixture(base: base, user: user, paths: paths)
    }

    private func make(_ f: Fixture, version: String? = "codex-cli 0.167.0",
                      launcher: FakeLauncher, connection: FakeConnection = FakeConnection(),
                      entries: [CodexAppServer.HookEntry] = [], ready: Bool = true,
                      profile: CodexProfile = .repoPane) -> CodexPaneRuntime {
        let userHome = f.user
        return CodexPaneRuntime(sessionID: "ABCD1234-0000-0000-0000-000000000000", cwd: "/r/app", profile: profile,
                         paths: f.paths, launcher: launcher,
                         threadName: "dure-모바일-ab12-app",
                         userCodexHome: f.user,
                         versionOutput: { version },
                         // CodexHome.prepare 와 같은 사용자 home 을 읽을 때만 목록을 준다 — 어긋나면 훅 테스트가 깨진다
                         inventory: { _, home in home == userHome ? entries : [] },
                         connect: { _ in connection },
                         socketReady: { _ in ready },
                         socketTimeout: 0.3,
                         shimPath: "/x/hook")
    }

    /// 콜백은 메인 큐로 넘어온다 — 조건이 설 때까지 양보하며 기다린다.
    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// 진짜 유닉스 소켓 파일 하나(bind 만, listen 안 함).
    private func bindSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(r == 0)
    }

    private func threadStarted(_ id: String, ephemeral: Bool = false) -> String {
        "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"\(id)\",\"cwd\":\"/r/app\",\"ephemeral\":\(ephemeral)}}}"
    }

    private func threadClosed(_ id: String) -> String {
        "{\"method\":\"thread/closed\",\"params\":{\"threadId\":\"\(id)\"}}"
    }

    // MARK: - 시작

    @Test func 시작하면_home_을_만들고_서버_스크립트를_띄운다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher(), conn = FakeConnection()
        let rt = make(f, launcher: launcher, connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        #expect(launcher.scripts.count == 1)
        let script = try #require(launcher.scripts.first)
        #expect(script.contains("export CODEX_HOME=\(Spawn.quoted(f.paths.home.path))"))
        #expect(script.contains("export DURE_SESSION='ABCD1234-0000-0000-0000-000000000000'"))
        #expect(script.contains("--listen \(Spawn.quoted("unix://" + f.paths.socket))"))
        #expect(script.contains("cd '/r/app' && exec codex app-server"))
        // 셸 인용 안의 TOML 문자열이라 shim 경로의 따옴표가 셸 이스케이프로 바뀐다.
        #expect(script.contains("command=\"'\\''/x/hook'\\'' SessionStart\""))
        #expect(launcher.logs == [f.paths.log])
        // home 에 사용자 config 사본 + cwd 신뢰 줄
        let config = try String(contentsOf: f.paths.home.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(config.hasPrefix("model = \"x\"\n"))
        #expect(config.contains("[projects.\"/r/app\"]"))
        // 소켓이 생기면 붙어서 initialize → initialized
        #expect(conn.methods == ["initialize", "initialized"])
        #expect(rt.failure == nil)
    }

    @Test func 훅_목록에서_끌_플러그인과_옮길_사용자_훅을_서버에_준다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let entries = [
            CodexAppServer.HookEntry(source: "plugin", pluginID: "p1@m", event: "Stop", matcher: nil,
                                     command: "x", timeout: 5, trusted: false),
            CodexAppServer.HookEntry(source: "user", pluginID: nil, event: "Stop", matcher: nil,
                                     command: "/u/dump.sh", timeout: 7, trusted: true,
                                     sourcePath: "/u/.codex/hooks.json"),
        ]
        let rt = make(f, launcher: launcher, entries: entries)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let script = try #require(launcher.scripts.first)
        #expect(script.contains("plugins.p1@m.enabled=false"))
        #expect(script.contains("/u/dump.sh"))
    }

    @Test func 사용자_config_toml_훅의_신뢰를_페인_home_사본_경로로_옮긴다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let entries = [
            CodexAppServer.HookEntry(source: "user", pluginID: nil, event: "SessionStart", matcher: "*",
                                     command: "from-config", timeout: 5, trusted: true,
                                     sourcePath: "/u/.codex/config.toml",
                                     key: "/u/.codex/config.toml:session_start:0:0", currentHash: "sha256:abc"),
        ]
        let rt = make(f, launcher: launcher, entries: entries)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let script = try #require(launcher.scripts.first)
        let key = f.paths.home.appendingPathComponent("config.toml").path + ":session_start:0:0"
        #expect(script.contains("\"\(key)\"={trusted_hash=\"sha256:abc\"}"))
        #expect(script.components(separatedBy: "hooks.state=").count == 2)   // 신뢰 표는 하나
        #expect(!script.contains("from-config"))   // 훅 자체는 config 사본에 있으므로 옮기지 않는다
    }

    @Test func 버전이_낮으면_실패_표식에_이유를_쓰고_서버를_띄우지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, version: "codex-cli 0.150.0", launcher: launcher)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        #expect(launcher.scripts.isEmpty)
        let marker = try String(contentsOfFile: f.paths.failMarker, encoding: .utf8)
        #expect(marker.contains("0.150.0") && marker.contains(CodexLaunch.minimumVersion))
        #expect(rt.failure == marker.trimmingCharacters(in: .newlines))
    }

    @Test func codex_가_없으면_실패_표식에_이유를_쓰고_서버를_띄우지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, version: nil, launcher: launcher)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        #expect(launcher.scripts.isEmpty)
        #expect(exists(f.paths.failMarker))
        #expect(rt.failure?.contains("codex") == true)
    }

    @Test func 묵은_실패_표식과_소켓은_시작하자마자_지운다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let run = URL(fileURLWithPath: f.paths.socket).deletingLastPathComponent()
        try fm.createDirectory(at: run, withIntermediateDirectories: true)
        try "옛 이유\n".write(toFile: f.paths.failMarker, atomically: true, encoding: .utf8)
        let target = f.base.appendingPathComponent("t.sock").path
        try bindSocket(at: target)
        try fm.createSymbolicLink(atPath: f.paths.socket, withDestinationPath: target)

        let rt = make(f, launcher: FakeLauncher())
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        // TUI 는 곧바로 뜬다 — 기다리지 않고 지워져 있어야 한다.
        #expect(!exists(f.paths.failMarker))
        #expect(!exists(f.paths.socket))
        #expect(!exists(target))
        rt.stop()
    }

    @Test func 소켓이_제때_안_생기면_실패_표식을_쓰고_서버를_끈다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher(), conn = FakeConnection()
        let rt = make(f, launcher: launcher, connection: conn, ready: false)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        #expect(launcher.handle.terminateCount == 1)
        #expect(conn.methods.isEmpty)
        #expect(rt.failure?.contains(f.paths.log) == true)
        #expect(exists(f.paths.failMarker))
    }

    // MARK: - 멈춤

    @Test func 멈추면_서버를_끄고_소켓_표식을_지우되_home_은_남긴다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher(), conn = FakeConnection()
        let rt = make(f, launcher: launcher, connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        // 서버가 만든 모양: 경로는 링크, 실제 소켓은 다른 곳(/private/tmp/codex-daemon-501/<hash>)
        let target = f.base.appendingPathComponent("t.sock").path
        try bindSocket(at: target)
        try fm.createSymbolicLink(atPath: f.paths.socket, withDestinationPath: target)
        try "x\n".write(toFile: f.paths.failMarker, atomically: true, encoding: .utf8)

        rt.stop()

        #expect(conn.cancelled == 1)
        #expect(launcher.handle.terminateCount == 1)
        #expect(!exists(f.paths.socket))
        #expect(!exists(target))
        #expect(!exists(f.paths.failMarker))
        #expect(fm.fileExists(atPath: f.paths.home.appendingPathComponent("config.toml").path))
    }

    @Test func 소켓_링크가_소켓이_아닌_것을_가리키면_링크만_지운다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let rt = make(f, launcher: FakeLauncher())
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let target = f.base.appendingPathComponent("plain.txt").path
        try "keep".write(toFile: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: f.paths.socket, withDestinationPath: target)

        rt.stop()

        #expect(!exists(f.paths.socket))
        #expect(fm.fileExists(atPath: target))
    }

    @Test func 두_번_멈춰도_안전하다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher(), conn = FakeConnection()
        let rt = make(f, launcher: launcher, connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        rt.stop()
        rt.stop()
        #expect(conn.cancelled == 1)
        #expect(launcher.handle.terminateCount == 1)
    }

    @Test func 서버가_먼저_죽으면_onServerExit_를_부른다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher)
        var exits = 0
        rt.start(onThreadStarted: { _ in }, onServerExit: { exits += 1 })
        await rt.startup?.value

        launcher.exit(1)
        #expect(await eventually { exits == 1 })
        #expect(rt.failure?.contains(f.paths.log) == true)
        launcher.exit(1)    // 두 번 와도 한 번만
        try? await Task.sleep(for: .milliseconds(50))
        #expect(exits == 1)
    }

    @Test func 멈춘_뒤_서버가_끝나면_onServerExit_를_부르지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher)
        var exits = 0
        rt.start(onThreadStarted: { _ in }, onServerExit: { exits += 1 })
        await rt.startup?.value
        rt.stop()
        launcher.exit(143)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(exits == 0)
        #expect(rt.failure == nil)
    }

    @Test func 뜨는_도중에_멈추면_늦게_뜬_서버도_꺼진다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher(blocking: true), conn = FakeConnection()
        let rt = make(f, launcher: launcher, connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        #expect(await eventually { launcher.scripts.count == 1 })   // launch 안에서 멈춰 있다

        rt.stop()
        #expect(launcher.handle.terminateCount == 0)                 // 아직 handle 이 없다
        launcher.gate?.signal()
        await rt.startup?.value

        #expect(launcher.handle.terminateCount == 1)
        #expect(conn.methods.isEmpty)                                 // 멈춘 뒤에는 붙지 않는다
    }

    // MARK: - 스레드

    @Test func 임시가_아닌_스레드마다_threadID_를_갱신하고_이름은_처음에만_붙인다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        var started: [String] = []
        rt.start(onThreadStarted: { started.append($0) }, onServerExit: {})
        await rt.startup?.value

        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        conn.deliver(threadStarted("title", ephemeral: true))        // 첫 턴의 "제목 만들기" 스레드
        conn.deliver(threadStarted("t2"))                              // /new · /clear
        #expect(await eventually { rt.threadID == "t2" })
        #expect(started == ["t1", "t2"])

        let names = conn.sent.filter { $0["method"] as? String == "thread/name/set" }
        #expect(names.count == 1)
        let params = names.first?["params"] as? [String: Any]
        #expect(params?["threadId"] as? String == "t1")
        #expect(params?["name"] as? String == "dure-모바일-ab12-app")
    }

    @Test func 지금_스레드가_아닌_thread_closed_는_무시한다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        conn.deliver(threadStarted("t1"))
        conn.deliver(threadStarted("t2"))
        conn.deliver(threadClosed("t1"))       // 60초 뒤 옛 스레드를 내린다
        conn.deliver(threadClosed("title"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == "t2")
        conn.deliver(threadClosed("t2"))
        #expect(await eventually { rt.threadID == nil })
    }

    @Test func 멈춘_뒤_늦게_온_메시지는_무시한다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        var started: [String] = []
        rt.start(onThreadStarted: { started.append($0) }, onServerExit: {})
        await rt.startup?.value
        rt.stop()

        conn.deliver(threadStarted("late"))    // cancel() 은 큐 비동기 — 콜백이 그 뒤에도 온다
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == nil)
        #expect(started.isEmpty)
    }

    // MARK: - 경로

    @Test func 경로는_세션_앞_8자와_페인_키에서_나온다() {
        let root = URL(fileURLWithPath: "/d/codex"), homes = URL(fileURLWithPath: "/d/codex-home")
        let p = CodexPaneRuntime.Paths.paths(forSession: "ABCD1234-EF56-0000-0000-000000000000", paneKey: "repo:r1",
                                             root: root, homeRoot: homes)
        #expect(p.socket == "/d/codex/abcd1234.sock")
        #expect(p.failMarker == "/d/codex/abcd1234.fail")
        #expect(p.log == "/d/codex/abcd1234.log")
        #expect(p.home.path == "/d/codex-home/repo-r1")
        let full = CodexPaneRuntime.Paths.paths(forSession: "ABCD1234-EF56-0000-0000-000000000000",
                                                paneKey: "orch:w1", fullID: true, root: root, homeRoot: homes)
        #expect(full.socket == "/d/codex/abcd1234ef5600000000000000000000.sock")
        #expect(full.home.path == "/d/codex-home/orch-w1")
    }
}
