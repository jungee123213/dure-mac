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

        /// 보낸 요청 중 그 method 의 id 들(보낸 순서).
        func ids(_ method: String) -> [Int] {
            sent.filter { $0["method"] as? String == method }.compactMap { $0["id"] as? Int }
        }
        func params(_ method: String) -> [[String: Any]] {
            sent.filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
        }
    }

    /// 깨우기 타이머 — 5초를 실제로 기다리지 않고 테스트가 직접 터뜨린다.
    final class FakeTimer {
        private(set) var delays: [TimeInterval] = []
        private var works: [@MainActor @Sendable () -> Void] = []
        var pending: Int { works.count }
        func add(_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
            delays.append(delay)
            works.append(work)
        }
        @MainActor func fire() {
            let w = works
            works = []
            for work in w { work() }
        }
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
                      profile: CodexProfile = .repoPane, mcpSocket: String? = nil,
                      gate: String? = "/A/Dure",
                      gateRunnable: @escaping (String) -> Bool = { _ in true },
                      timer: FakeTimer = FakeTimer()) -> CodexPaneRuntime {
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
                         shimPath: "/x/hook", mcpSocket: mcpSocket,
                         gateExecutable: gate, isExecutable: gateRunnable,
                         schedule: { timer.add($0, $1) })
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

    private func status(_ id: String, _ type: String) -> String {
        let flags = type == "active" ? ",\"activeFlags\":[]" : ""
        return "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"\(id)\",\"status\":{\"type\":\"\(type)\"\(flags)}}}"
    }

    private func ok(_ id: Int) -> String { "{\"id\":\(id),\"result\":{}}" }

    private func loaded(_ id: Int, _ threads: [String]) -> String {
        let list = threads.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"id\":\(id),\"result\":{\"data\":[\(list)],\"nextCursor\":null}}"
    }

    private func read(_ id: Int, _ thread: String, cwd: String = "/r/app", ephemeral: Bool = false,
                      status: String = "idle") -> String {
        "{\"id\":\(id),\"result\":{\"thread\":{\"id\":\"\(thread)\",\"cwd\":\"\(cwd)\",\"ephemeral\":\(ephemeral),\"status\":{\"type\":\"\(status)\"},\"turns\":[]},\"readState\":null}}"
    }

    /// 시작해서 initialize 응답까지 준다(보충이 돈다).
    private func connected(_ f: Fixture, _ conn: FakeConnection, timer: FakeTimer = FakeTimer(),
                           onThread: @escaping (String) -> Void = { _ in }) async -> CodexPaneRuntime {
        let rt = make(f, launcher: FakeLauncher(), connection: conn, timer: timer)
        rt.start(onThreadStarted: onThread, onServerExit: {})
        await rt.startup?.value
        return rt
    }

    /// 보충 한 바퀴 — loaded list 응답 → 스레드마다 thread/read 응답(목록 순서대로).
    private func answerRecovery(_ conn: FakeConnection, listIndex: Int = 0,
                                _ threads: [(id: String, cwd: String, ephemeral: Bool)]) async {
        _ = await eventually { conn.ids("thread/loaded/list").count > listIndex }
        guard let list = conn.ids("thread/loaded/list").dropFirst(listIndex).first else { return }
        let before = conn.ids("thread/read").count
        conn.deliver(loaded(list, threads.map(\.id)))
        _ = await eventually { conn.ids("thread/read").count == before + threads.count }
        let reads = Array(conn.ids("thread/read").dropFirst(before))
        for (rid, t) in zip(reads, threads) { conn.deliver(read(rid, t.id, cwd: t.cwd, ephemeral: t.ephemeral)) }
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

    @Test func 런타임은_MCP_소켓을_서버_스크립트에_넣는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher, mcpSocket: "/s/m.sock")
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let script = try #require(launcher.scripts.first)
        #expect(script.contains("'mcp_servers.dure.args=[\"-U\",\"/s/m.sock\"]'"))
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

    // MARK: - 게이트 · 조율자 거절 (Task 4)

    @Test func 레포_페인_서버에는_게이트_훅을_주고_거절_훅은_주지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher, gate: "/Applications/My Apps/Dure.app/Contents/MacOS/Dure")
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let script = try #require(launcher.scripts.first)
        let expected = CodexHooks.configArguments(
            CodexHooks.dureGroups(shimPath: "/x/hook", profile: .repoPane,
                                  gateExecutable: "/Applications/My Apps/Dure.app/Contents/MacOS/Dure"))
        for value in stride(from: 1, to: expected.count, by: 2).map({ expected[$0] }) {
            #expect(script.contains("-c " + Spawn.quoted(value)))
        }
        #expect(script.contains("--dure-codex-gate"))
        #expect(!script.contains("hookSpecificOutput"))
        #expect(fm.fileExists(atPath: f.paths.home.appendingPathComponent("rules/dure.rules").path))
        #expect(rt.failure == nil)
    }

    @Test func 조율자_서버에는_거절_훅을_주고_게이트는_주지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        // 조율자는 게이트를 쓰지 않으니 실행 파일 경로가 없어도 뜬다
        let rt = make(f, launcher: launcher, profile: .orchestrator, gate: nil)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        let script = try #require(launcher.scripts.first)
        #expect(script.contains("hookSpecificOutput"))
        #expect(script.contains("permission_request:0:0"))
        #expect(!script.contains("permission_request:1:0"))
        #expect(!script.contains("/x/hook'\\'' PermissionRequest"))   // shim PermissionRequest 없음(D-11)
        #expect(!script.contains("--dure-codex-gate"))
        #expect(!fm.fileExists(atPath: f.paths.home.appendingPathComponent("rules/dure.rules").path))
        #expect(rt.failure == nil)
    }

    @Test func 게이트_실행_파일을_모르면_레포_페인은_띄우지_않고_실패_표식에_쓴다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher, gate: nil)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value

        #expect(launcher.scripts.isEmpty)
        let marker = try String(contentsOfFile: f.paths.failMarker, encoding: .utf8)
        #expect(marker.contains("게이트"))
        #expect(rt.failure == marker.trimmingCharacters(in: .newlines))
    }

    @Test func 게이트_실행_파일을_실행할_수_없으면_레포_페인은_띄우지_않고_실패_표식에_쓴다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        // 실제 확인(`isRunnable`)으로 — 실행 권한 없는 파일 · 없는 파일
        let plain = f.base.appendingPathComponent("Dure-plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        for path in [plain.path, f.base.appendingPathComponent("없음/Dure").path] {
            try? fm.removeItem(atPath: f.paths.failMarker)
            let launcher = FakeLauncher()
            let rt = make(f, launcher: launcher, gate: path, gateRunnable: CodexPaneRuntime.isRunnable)
            rt.start(onThreadStarted: { _ in }, onServerExit: {})
            await rt.startup?.value
            #expect(launcher.scripts.isEmpty)
            let marker = try String(contentsOfFile: f.paths.failMarker, encoding: .utf8)
            #expect(marker.contains("게이트") && marker.contains(path))
            #expect(rt.failure == marker.trimmingCharacters(in: .newlines))
        }
        // 실행 권한이 있으면 뜬다
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher, gate: plain.path, gateRunnable: CodexPaneRuntime.isRunnable)
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        #expect(launcher.scripts.count == 1)
        #expect(rt.failure == nil)
        rt.stop()
    }

    @Test func 조율자는_게이트_실행_파일_확인을_하지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let launcher = FakeLauncher()
        let rt = make(f, launcher: launcher, profile: .orchestrator, gate: "/없음/Dure", gateRunnable: { _ in false })
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        #expect(launcher.scripts.count == 1)
        #expect(rt.failure == nil)
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

    // MARK: - 2단계 주소 보충 (thread/loaded/list → thread/read)

    @Test func 연결_뒤_스레드가_없으면_loaded_list_로_보충한다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(conn.ids("thread/loaded/list").isEmpty)            // initialize 응답 전에는 묻지 않는다

        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        await answerRecovery(conn, [("t9", "/r/app", false)])
        #expect(await eventually { rt.threadID == "t9" })
        #expect(started == ["t9"])                                   // 새 스레드와 같은 길로 알린다
        #expect(rt.address == .codex(socket: f.paths.socket, thread: "t9"))
        #expect(conn.params("thread/read").first?["threadId"] as? String == "t9")
        // 이름도 같은 길로 붙는다
        #expect(conn.params("thread/name/set").first?["threadId"] as? String == "t9")
    }

    @Test func loaded_list_에_같은_cwd_스레드가_둘이면_고르지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        // /new 직후 약 60초 — 옛 · 새 스레드가 둘 다 loaded
        await answerRecovery(conn, [("old", "/r/app", false), ("new", "/r/app", false)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == nil)
        #expect(rt.address == nil)
        #expect(started.isEmpty)
        #expect(conn.ids("thread/name/set").isEmpty)

        conn.deliver(threadStarted("next"))                          // 다음 thread/started 를 기다린다
        #expect(await eventually { rt.threadID == "next" })
        #expect(started == ["next"])
    }

    @Test func 옛_스레드가_내려가면_다시_보충한다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        await answerRecovery(conn, [("old", "/r/app", false), ("new", "/r/app", false)])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == nil)

        conn.deliver(threadClosed("old"))                             // 60초 뒤 옛 스레드가 내려간다
        await answerRecovery(conn, listIndex: 1, [("new", "/r/app", false)])
        #expect(await eventually { rt.threadID == "new" })
        #expect(started == ["new"])
    }

    @Test func ephemeral_스레드는_보충에서_빠진다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = await connected(f, conn)
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        await answerRecovery(conn, [("title", "/r/app", true), ("t1", "/r/app", false)])
        #expect(await eventually { rt.threadID == "t1" })
    }

    @Test func 이미_thread_started_를_받았으면_보충하지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(threadStarted("t1"))
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(conn.ids("thread/loaded/list").isEmpty)
        #expect(rt.threadID == "t1")
        #expect(started == ["t1"])
    }

    @Test func 보충_도중에_thread_started_가_오면_보충_결과를_버린다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        _ = await eventually { !conn.ids("thread/loaded/list").isEmpty }
        conn.deliver(loaded(conn.ids("thread/loaded/list")[0], ["old"]))
        _ = await eventually { !conn.ids("thread/read").isEmpty }
        conn.deliver(threadStarted("t1"))
        conn.deliver(read(conn.ids("thread/read")[0], "old"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == "t1")
        #expect(started == ["t1"])
    }

    @Test func 실패한_initialize_뒤에는_보충하지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        _ = await connected(f, conn)
        let id = try #require(conn.ids("initialize").first)
        conn.deliver("{\"id\":\(id),\"error\":{\"code\":-32600,\"message\":\"x\"}}")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(conn.ids("thread/loaded/list").isEmpty)
    }

    /// 최종 리뷰 M1 — `thread` 없는 thread/read 성공은 `.response(ok: true)` 로 온다. 그래도 기다림에서 빠져야 보충이 끝난다.
    @Test func thread_없는_thread_read_성공도_기다림에서_빠진다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        _ = await eventually { !conn.ids("thread/loaded/list").isEmpty }
        conn.deliver(loaded(conn.ids("thread/loaded/list")[0], ["bad", "t1"]))
        _ = await eventually { conn.ids("thread/read").count == 2 }
        let reads = conn.ids("thread/read")
        conn.deliver(ok(reads[0]))                                    // 모양이 어긋난 성공
        conn.deliver(read(reads[1], "t1"))
        #expect(await eventually { rt.threadID == "t1" })              // 남은 하나로 판정이 끝난다
        #expect(started == ["t1"])
    }

    @Test func 모양이_어긋난_응답만_와도_다음_보충이_막히지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = await connected(f, conn)
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        _ = await eventually { !conn.ids("thread/loaded/list").isEmpty }
        conn.deliver(loaded(conn.ids("thread/loaded/list")[0], ["bad"]))
        _ = await eventually { conn.ids("thread/read").count == 1 }
        conn.deliver(ok(conn.ids("thread/read")[0]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == nil)
        // 다음 기회(thread/closed)에 다시 묻는다 — 기다림이 남아 있으면 recover 가 아무것도 안 보낸다.
        conn.deliver(threadClosed("bad"))
        await answerRecovery(conn, listIndex: 1, [("t1", "/r/app", false)])
        #expect(await eventually { rt.threadID == "t1" })
    }

    /// 최종 리뷰 M3 — 서브에이전트 스레드(`parentThreadId` 있음)는 전달 주소가 아니다.
    @Test func 서브에이전트_thread_started_는_주소로_잡지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var started: [String] = []
        let rt = await connected(f, conn) { started.append($0) }
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        conn.deliver("{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"sub\",\"cwd\":\"/r/app\",\"ephemeral\":false,\"parentThreadId\":\"t1\"}}}")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rt.threadID == "t1")
        #expect(started == ["t1"])
    }

    @Test func 서브에이전트_스레드는_보충에서_빠진다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = await connected(f, conn)
        conn.deliver(ok(try #require(conn.ids("initialize").first)))
        _ = await eventually { !conn.ids("thread/loaded/list").isEmpty }
        conn.deliver(loaded(conn.ids("thread/loaded/list")[0], ["sub", "t1"]))
        _ = await eventually { conn.ids("thread/read").count == 2 }
        let reads = conn.ids("thread/read")
        conn.deliver("{\"id\":\(reads[0]),\"result\":{\"thread\":{\"id\":\"sub\",\"cwd\":\"/r/app\",\"ephemeral\":false,\"parentThreadId\":\"t1\",\"status\":{\"type\":\"active\"}}}}")
        conn.deliver(read(reads[1], "t1"))
        #expect(await eventually { rt.threadID == "t1" })              // 같은 cwd 둘이 아니라 하나로 판정
    }

    @Test func 보충_판정은_cwd_가_같고_임시가_아닌_스레드가_하나일_때만_고른다() {
        typealias T = CodexPaneRuntime.LoadedThread
        let cwd = "/Users/x/work/repo"
        #expect(CodexPaneRuntime.adoptable([T(id: "a", cwd: cwd, ephemeral: false)], cwd: cwd) == "a")
        #expect(CodexPaneRuntime.adoptable([T(id: "a", cwd: cwd + "/", ephemeral: false)], cwd: cwd) == "a")   // 끝 / 무시
        #expect(CodexPaneRuntime.adoptable([T(id: "a", cwd: cwd, ephemeral: false),
                                            T(id: "b", cwd: cwd, ephemeral: false)], cwd: cwd) == nil)
        #expect(CodexPaneRuntime.adoptable([T(id: "t", cwd: cwd, ephemeral: true),
                                            T(id: "a", cwd: cwd, ephemeral: false)], cwd: cwd) == "a")
        #expect(CodexPaneRuntime.adoptable([T(id: "o", cwd: "/elsewhere", ephemeral: false),
                                            T(id: "a", cwd: cwd, ephemeral: false)], cwd: cwd) == "a")
        #expect(CodexPaneRuntime.adoptable([T(id: "n", cwd: nil, ephemeral: false)], cwd: cwd) == nil)
        #expect(CodexPaneRuntime.adoptable([], cwd: cwd) == nil)
        #expect(CodexPaneRuntime.adoptable([T(id: "s", cwd: cwd, ephemeral: false, parentThreadID: "a"),
                                            T(id: "a", cwd: cwd, ephemeral: false)], cwd: cwd) == "a")     // 서브에이전트 빼고
    }

    // MARK: - 2단계 멈춘 큐 깨우기 (thread/queue/start)

    @Test func 전달_뒤_5초_안에_active_가_아니면_queue_start_를_보낸다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })

        rt.nudgeQueue()
        #expect(timer.delays == [5])
        timer.fire()
        #expect(conn.params("thread/queue/start").map { $0["threadId"] as? String } == ["t1"])
        timer.fire()                                                   // 한 번만
        #expect(conn.ids("thread/queue/start").count == 1)
        // 실험 API 실패는 로그만 — 런타임이 멀쩡하다
        conn.deliver("{\"id\":\(conn.ids("thread/queue/start")[0]),\"error\":{\"code\":-32600,\"message\":\"x\"}}")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rt.threadID == "t1")
        #expect(rt.failure == nil)
    }

    @Test func 전달_뒤_active_가_되면_queue_start_를_보내지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })

        rt.nudgeQueue()
        conn.deliver(status("other", "active"))                       // 다른 스레드는 상관없다
        conn.deliver(status("t1", "active"))
        try? await Task.sleep(for: .milliseconds(50))
        timer.fire()
        #expect(conn.ids("thread/queue/start").isEmpty)
    }

    @Test func 턴_중에_전달하면_턴이_끝난_뒤부터_5초를_잰다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        conn.deliver(threadStarted("t1"))
        conn.deliver(status("t1", "active"))                          // 승인 대기 등 — 큐는 턴이 끝나야 돈다
        #expect(await eventually { rt.threadID == "t1" })
        try? await Task.sleep(for: .milliseconds(30))

        rt.nudgeQueue()
        #expect(timer.pending == 0)                                   // 도는 턴에 queue/start 를 끼우지 않는다
        conn.deliver(status("t1", "active"))                          // 승인 → 같은 턴(active → active)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(timer.pending == 0)
        conn.deliver(status("t1", "idle"))                            // 사람이 Esc 로 끊음 → 큐가 멈출 수 있다
        #expect(await eventually { timer.pending == 1 })
        timer.fire()
        #expect(conn.params("thread/queue/start").map { $0["threadId"] as? String } == ["t1"])
    }

    @Test func 턴이_끝난_뒤_큐가_돌면_보내지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        conn.deliver(threadStarted("t1"))
        conn.deliver(status("t1", "active"))
        #expect(await eventually { rt.threadID == "t1" })
        try? await Task.sleep(for: .milliseconds(30))

        rt.nudgeQueue()
        conn.deliver(status("t1", "idle"))
        conn.deliver(status("t1", "active"))                          // 큐의 다음 항목이 턴으로
        try? await Task.sleep(for: .milliseconds(50))
        timer.fire()
        #expect(conn.ids("thread/queue/start").isEmpty)
    }

    @Test func 스레드가_없거나_바뀌면_깨우지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        rt.nudgeQueue()                                                // 주소 없음
        #expect(timer.pending == 0)

        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        rt.nudgeQueue()
        conn.deliver(threadStarted("t2"))                             // /new — 옛 스레드 배분은 SessionStart 가 닫는다
        #expect(await eventually { rt.threadID == "t2" })
        timer.fire()
        #expect(conn.ids("thread/queue/start").isEmpty)
    }

    @Test func 멈춘_뒤에는_깨우지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection(), timer = FakeTimer()
        let rt = await connected(f, conn, timer: timer)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        rt.nudgeQueue()
        rt.stop()
        timer.fire()
        #expect(conn.ids("thread/queue/start").isEmpty)
    }

    // MARK: - 경로

    // MARK: - 한도

    private func initialize(_ conn: FakeConnection) async throws {
        let id = try #require(conn.ids("initialize").first)
        conn.deliver(ok(id))
        // 응답은 메인 큐로 넘어온다 — 읽기 요청이 나갈 때까지 기다린다
        _ = await eventually { !conn.ids("account/rateLimits/read").isEmpty }
    }

    private let updatedLimits = """
    {"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1795174118},"secondary":null,"planType":null,"rateLimitReachedType":null}}}
    """

    private func errorJSON(_ info: String, willRetry: Bool, thread: String = "t1") -> String {
        "{\"method\":\"error\",\"params\":{\"error\":{\"message\":\"m\",\"codexErrorInfo\":\(info)},\"willRetry\":\(willRetry),\"threadId\":\"\(thread)\",\"turnId\":\"u1\"}}"
    }

    @Test func readsRateLimitsAfterInitialize() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var got: [(CodexRateLimits, Bool)] = []
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {}, onRateLimits: { got.append(($0, $1)) })
        await rt.startup?.value
        #expect(conn.ids("account/rateLimits/read").isEmpty)    // initialize 응답 전에는 읽지 않는다
        try await initialize(conn)
        let rid = try #require(conn.ids("account/rateLimits/read").first)
        #expect(conn.params("account/rateLimits/read").first?["excludeResetCreditDetails"] as? Bool == true)
        conn.deliver("{\"id\":\(rid),\"result\":{\"ordinaryUsageAllowed\":true,\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300,\"resetsAt\":9},\"secondary\":null,\"planType\":\"plus\",\"rateLimitReachedType\":null}}}")
        #expect(await eventually { got.count == 1 })
        conn.deliver(updatedLimits)
        #expect(await eventually { got.count == 2 })
        #expect(got[0].1 == true)
        #expect(got[0].0.planType == "plus")
        #expect(got[0].0.ordinaryUsageAllowed == true)
        #expect(got[1].1 == false)
        #expect(got[1].0.primary?.usedPercent == 42)
    }

    @Test func 한도_읽기가_오류로_오면_콜백이_없다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var count = 0
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {}, onRateLimits: { _, _ in count += 1 })
        await rt.startup?.value
        try await initialize(conn)
        let rid = try #require(conn.ids("account/rateLimits/read").first)
        conn.deliver("{\"id\":\(rid),\"error\":{\"code\":-32600,\"message\":\"auth\"}}")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(count == 0)
    }

    @Test func 실패한_initialize_뒤에는_한도를_읽지_않는다() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        _ = await connected(f, conn)
        let id = try #require(conn.ids("initialize").first)
        conn.deliver("{\"id\":\(id),\"error\":{\"code\":-32600,\"message\":\"x\"}}")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(conn.ids("account/rateLimits/read").isEmpty)
    }

    @Test func retryingErrorIsNotLimit() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var threads: [String] = []
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {}, onUsageLimit: { threads.append($0) })
        await rt.startup?.value
        conn.deliver(errorJSON("\"usageLimitExceeded\"", willRetry: true))
        conn.deliver(errorJSON("\"serverOverloaded\"", willRetry: false))
        conn.deliver(errorJSON("{\"responseStreamDisconnected\":{\"httpStatusCode\":null}}", willRetry: true))
        try? await Task.sleep(for: .milliseconds(80))
        #expect(threads.isEmpty)
        conn.deliver(errorJSON("\"usageLimitExceeded\"", willRetry: false, thread: "t9"))
        #expect(await eventually { threads == ["t9"] })
    }

    /// 지금 스레드의 재시도 없는 429 는 모양(`codexErrorInfo`)과 상관없이 한도 초과다 — 막힘 콜백을 한 번 부르고 한도도 다시 읽는다.
    @Test func http429FailureRereadsLimits() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var threads: [String] = []
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {}, onUsageLimit: { threads.append($0) })
        await rt.startup?.value
        try await initialize(conn)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        #expect(conn.ids("account/rateLimits/read").count == 1)
        // 429 지만 재시도 중이면 읽지도 막지도 않는다
        conn.deliver(errorJSON("{\"responseTooManyFailedAttempts\":{\"httpStatusCode\":429}}", willRetry: true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(conn.ids("account/rateLimits/read").count == 1)
        #expect(threads.isEmpty)
        conn.deliver(errorJSON("{\"responseTooManyFailedAttempts\":{\"httpStatusCode\":429}}", willRetry: false))
        #expect(await eventually { conn.ids("account/rateLimits/read").count == 2 })
        #expect(threads == ["t1"])
        // 다른 모양의 429 도 같다
        conn.deliver(errorJSON("{\"httpConnectionFailed\":{\"httpStatusCode\":429}}", willRetry: false))
        #expect(await eventually { conn.ids("account/rateLimits/read").count == 3 })
        #expect(threads == ["t1", "t1"])
    }

    /// 지금 스레드가 아닌 429(서브에이전트 · `/new` 앞의 옛 스레드)는 이 페인의 턴이 끊긴 게 아니다 — 다시 읽기만 한다.
    @Test func http429OnOtherThreadOnlyRereads() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        var threads: [String] = []
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        rt.start(onThreadStarted: { _ in }, onServerExit: {}, onUsageLimit: { threads.append($0) })
        await rt.startup?.value
        try await initialize(conn)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        conn.deliver(errorJSON("{\"responseTooManyFailedAttempts\":{\"httpStatusCode\":429}}", willRetry: false, thread: "sub"))
        #expect(await eventually { conn.ids("account/rateLimits/read").count == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(threads.isEmpty)
    }

    /// 턴이 도는 중인가는 서버의 스레드 상태로 안다 — 지금 스레드의 `active` 일 때만.
    @Test func turnActiveFollowsThreadStatus() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = await connected(f, conn)
        #expect(!rt.isTurnActive)
        conn.deliver(threadStarted("t1"))
        #expect(await eventually { rt.threadID == "t1" })
        #expect(!rt.isTurnActive)
        conn.deliver(status("t1", "active"))
        #expect(await eventually { rt.isTurnActive })
        conn.deliver(status("other", "idle"))           // 다른 스레드는 상관없다
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rt.isTurnActive)
        conn.deliver(status("t1", "idle"))
        #expect(await eventually { !rt.isTurnActive })
        conn.deliver(status("t1", "active"))
        #expect(await eventually { rt.isTurnActive })
        conn.deliver(threadStarted("t2"))               // /new — 새 스레드는 아직 상태를 모른다
        #expect(await eventually { rt.threadID == "t2" })
        #expect(!rt.isTurnActive)
    }

    @Test func readRateLimitsWithoutConnectionReturnsFalse() async throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let conn = FakeConnection()
        let rt = make(f, launcher: FakeLauncher(), connection: conn)
        #expect(rt.readRateLimits() == false)         // 시작 전
        rt.start(onThreadStarted: { _ in }, onServerExit: {})
        await rt.startup?.value
        #expect(rt.readRateLimits() == false)         // 연결은 있어도 initialize 전
        #expect(conn.ids("account/rateLimits/read").isEmpty)
        try await initialize(conn)
        let before = conn.ids("account/rateLimits/read").count
        #expect(rt.readRateLimits() == true)
        #expect(conn.ids("account/rateLimits/read").count == before + 1)
        rt.stop()
        #expect(rt.readRateLimits() == false)
    }

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
