import Darwin
import Foundation

// MARK: - 주입 지점

/// 띄운 서버 프로세스 하나. `terminate` 는 SIGTERM(남으면 나중에 SIGKILL) — 두 번 불러도 된다.
nonisolated protocol CodexProcessHandle: Sendable {
    func terminate()
}

/// 서버 스크립트를 백그라운드 프로세스로 띄운다. 실제는 `Process` + `/bin/zsh -ilc`, 테스트는 가짜.
/// 메인 밖(분리된 작업)에서 불린다.
nonisolated protocol CodexProcessLaunching: Sendable {
    func launch(script: String, logPath: String, onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexProcessHandle
}

/// `CodexAppServerConnection` 의 모양. 테스트가 가짜 연결을 넣는다.
nonisolated protocol CodexServerConnecting: AnyObject, Sendable {
    func start(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
    func send(_ data: Data)
    func cancel()
}

nonisolated extension CodexAppServerConnection: CodexServerConnecting {}

// MARK: - 런타임

/// Codex 페인 하나의 전용 `codex app-server` 수명(스펙 1절). TUI(PTY)는 뷰가 띄우고, 서버 · 두레 연결은 여기가 쥔다.
///
/// 시작: 묵은 소켓 · 실패 표식 지우기(동기 — TUI 가 곧 뜬다) → `codex --version` → `CodexHome.prepare` →
/// 훅 목록(`CodexHookInventory`) → 서버 스크립트 실행 → 소켓 대기 → WebSocket 연결 → `initialize`/`initialized`.
/// 실패하면 이유를 실패 표식에 쓴다 — TUI 스크립트가 그것을 찍고 끝나며, 스토어는 `failure` 를 페인 문제로 옮긴다.
///
/// 멈춤: 연결 닫기 → 서버 SIGTERM → 소켓(링크와 그 대상) · 표식 지우기. **home 은 남긴다** — 서버가 rollout 경로를
/// home 아래로 적어서 지우면 사용자 Codex 가 그 기록을 못 연다(f-stage1 판정 2).
@MainActor
final class CodexPaneRuntime {

    struct Paths: Equatable {
        let home: URL
        let socket: String
        let failMarker: String
        let log: String

        /// 소켓 · 표식 · 로그는 `DURE_SESSION` 앞 8자(소문자 영숫자), home 은 페인 키(`repo-<id>` · `orch-<ws>`).
        /// 살아 있는 다른 페인과 8자가 겹치면 `fullID` 로 전체 UUID 를 쓴다(MCP 소켓과 같은 처리).
        nonisolated static func paths(forSession sessionID: String, paneKey: String, fullID: Bool = false,
                                      root: URL = CodexLaunch.defaultRoot,
                                      homeRoot: URL = CodexHome.defaultRoot) -> Paths {
            let clean = sessionID.lowercased().filter { $0.isLetter || $0.isNumber }
            let id = fullID ? clean : String(clean.prefix(8))
            return Paths(home: CodexHome.url(forPaneKey: paneKey, root: homeRoot),
                         socket: CodexLaunch.socketPath(forSession: id, root: root),
                         failMarker: CodexLaunch.failMarkerPath(forSession: id, root: root),
                         log: CodexLaunch.logPath(forSession: id, root: root))
        }
    }

    /// 서버를 띄운 때부터 소켓을 기다리는 시간(스펙 1절 "최대 10초").
    nonisolated static let defaultSocketTimeout: TimeInterval = 10
    /// `codex --version` 을 기다리는 시간.
    nonisolated static let versionTimeout: TimeInterval = 15

    nonisolated static var defaultUserCodexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    let sessionID: String
    let cwd: String
    let profile: CodexProfile
    let paths: Paths

    private let launcher: CodexProcessLaunching
    private let threadName: String?
    private let userCodexHome: URL
    private let versionOutput: @Sendable () async -> String?
    /// (cwd, 사용자 Codex home) → 훅 목록. `CodexHome.prepare` 와 같은 home 을 읽는다.
    private let inventory: @Sendable (String, URL) async -> [CodexAppServer.HookEntry]
    private let connect: (String) -> any CodexServerConnecting
    private let socketReady: (String) -> Bool
    private let socketTimeout: TimeInterval
    private let shimPath: String

    /// 지금 TUI 가 쓰는 스레드(= 훅 `session_id`). `/new` · `/clear` 마다 바뀐다. 임시(제목) 스레드는 잡지 않는다.
    private(set) var threadID: String?
    /// 시작하지 못했거나 서버가 먼저 끝난 이유. 스토어가 페인 문제로 옮긴다.
    private(set) var failure: String?
    /// 시작 작업. 테스트가 끝날 때까지 기다린다.
    private(set) var startup: Task<Void, Never>?

    private var handle: (any CodexProcessHandle)?
    private var connection: (any CodexServerConnecting)?
    private var began = false
    private var stopped = false
    private var serverExited = false
    private var named = false
    private var nextRequestID = 1
    private var onThreadStarted: ((String) -> Void)?
    private var onServerExit: (() -> Void)?

    init(sessionID: String, cwd: String, profile: CodexProfile, paths: Paths, launcher: CodexProcessLaunching,
         threadName: String? = nil,
         userCodexHome: URL = CodexPaneRuntime.defaultUserCodexHome,
         versionOutput: @escaping @Sendable () async -> String? = { await CodexPaneRuntime.liveVersionOutput() },
         inventory: @escaping @Sendable (String, URL) async -> [CodexAppServer.HookEntry] = {
             await CodexHookInventory.load(cwd: $0, userCodexHome: $1)
         },
         connect: @escaping (String) -> any CodexServerConnecting = { CodexAppServerConnection(socketPath: $0) },
         socketReady: @escaping (String) -> Bool = { CodexPaneRuntime.isSocket($0) },
         socketTimeout: TimeInterval = CodexPaneRuntime.defaultSocketTimeout,
         shimPath: String? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.profile = profile
        self.paths = paths
        self.launcher = launcher
        self.threadName = threadName
        self.userCodexHome = userCodexHome
        self.versionOutput = versionOutput
        self.inventory = inventory
        self.connect = connect
        self.socketReady = socketReady
        self.socketTimeout = socketTimeout
        // 기본 인자는 격리 밖에서 평가된다 — 메인액터 값(`HookBridge.shimURL`)은 본문에서 읽는다.
        self.shimPath = shimPath ?? HookBridge.shimURL.path
    }

    /// 한 번만 시작한다. 콜백은 메인에서 부른다. `onServerExit` 는 `stop()` 없이 서버가 끝났을 때만.
    func start(onThreadStarted: @escaping (String) -> Void, onServerExit: @escaping () -> Void) {
        guard !began, !stopped else { return }
        began = true
        self.onThreadStarted = onThreadStarted
        self.onServerExit = onServerExit
        // TUI 스크립트는 표식이 **있기만** 해도 끝난다 — 지난 기동의 찌꺼기를 지금 지운다(기다리면 늦는다).
        Self.removeSocket(paths.socket)
        try? FileManager.default.removeItem(atPath: paths.failMarker)
        for dir in Set([paths.socket, paths.failMarker, paths.log].map { ($0 as NSString).deletingLastPathComponent }) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        startup = Task { [weak self] in await self?.run() }
    }

    /// 연결 닫기 → 서버 SIGTERM → 소켓 · 표식 지우기. home 은 남긴다. 두 번 불러도 된다.
    /// 띄우는 중에 불리면 늦게 도착한 서버도 끈다(`run` 이 handle 을 받자마자 본다).
    func stop() {
        guard !stopped else { return }
        stopped = true
        startup?.cancel()
        connection?.cancel()
        connection = nil
        handle?.terminate()
        handle = nil
        Self.removeSocket(paths.socket)
        try? FileManager.default.removeItem(atPath: paths.failMarker)
        onThreadStarted = nil
        onServerExit = nil
    }

    // MARK: - 시작 순서

    private func run() async {
        let version = await versionOutput()
        guard !stopped else { return }
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            fail("codex 를 찾지 못했습니다 — 터미널에서 `codex --version` 이 되는지 확인하세요")
            return
        }
        guard CodexLaunch.isSupported(versionOutput: version) else {
            fail("codex 버전이 낮습니다(\(version)) — \(CodexLaunch.minimumVersion) 이상이 필요합니다")
            return
        }

        do {
            try CodexHome.prepare(profile: profile, cwd: cwd, userHome: userCodexHome, into: paths.home)
        } catch {
            fail("Codex 페인 home 을 준비하지 못했습니다: \(error.localizedDescription)")
            return
        }

        let entries = await inventory(cwd, userCodexHome)
        guard !stopped else { return }
        let groups = CodexHooks.dureGroups(shimPath: shimPath) + CodexAppServer.userGroupsToCarry(entries)
        // 사용자 config.toml [hooks] 는 사본에 딸려 가지만 신뢰 키의 파일 경로가 사본 경로로 바뀐다 — 신뢰만 다시 건다.
        let configTrust = CodexAppServer.configTrustToCarry(
            entries, paneConfigPath: paths.home.appendingPathComponent("config.toml").path)
        let disabled = CodexAppServer.pluginsToDisable(entries)
        if !disabled.isEmpty {
            NSLog("[Dure] Codex 페인 \(sessionID): 신뢰 안 된 훅이 있는 플러그인을 끕니다 — \(disabled.joined(separator: ", "))")
        }
        let script = CodexLaunch.serverScript(cwd: cwd, sessionID: sessionID, home: paths.home.path,
                                              socket: paths.socket,
                                              hookArguments: CodexHooks.configArguments(groups, extraTrust: configTrust),
                                              disabledPlugins: disabled)

        // `Process.run` 은 메인 밖에서. 그 사이 stop 이 오면 늦게 도착한 handle 을 바로 끈다.
        let launcher = launcher, log = paths.log
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            // 메인 큐는 순서를 지킨다 — 메시지 콜백과 같은 길로 넘어간다.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.serverDidExit(status) } }
        }
        let launched = await Task.detached(priority: .userInitiated) {
            Result { try launcher.launch(script: script, logPath: log, onExit: onExit) }
        }.value
        switch launched {
        case .failure(let error):
            if !stopped { fail("Codex 서버를 띄우지 못했습니다: \(error.localizedDescription)") }
            return
        case .success(let h):
            guard !stopped else { h.terminate(); return }
            handle = h
        }
        guard !serverExited else { return }

        // TUI 도 같은 소켓을 기다린다. 두레가 먼저 붙어야 thread/started 를 놓치지 않으니 촘촘히 본다.
        let deadline = Date().addingTimeInterval(socketTimeout)
        while !socketReady(paths.socket) {
            if stopped || serverExited { return }
            if Date() >= deadline {
                fail("Codex 서버가 \(Self.seconds(socketTimeout))초 안에 소켓을 만들지 않았습니다 — 로그: \(paths.log)")
                handle?.terminate()
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !stopped, !serverExited else { return }
        attach()
    }

    private func attach() {
        let conn = connect(paths.socket)
        connection = conn
        let id = ObjectIdentifier(conn)
        // cancel() 은 큐 비동기라 그 뒤에도 콜백이 온다 — 연결 인스턴스로 거른다(receive · closed).
        conn.start(onMessage: { [weak self] data in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data, from: id) } }
        }, onClose: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connectionClosed(id) } }
        })
        conn.send(CodexAppServer.initialize(id: requestID()))
        conn.send(CodexAppServer.initialized())
    }

    private func requestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    // MARK: - 들어오는 것 (메인)

    private func current(_ id: ObjectIdentifier) -> (any CodexServerConnecting)? {
        guard !stopped, let c = connection, ObjectIdentifier(c) == id else { return nil }
        return c
    }

    private func receive(_ data: Data, from id: ObjectIdentifier) {
        guard let conn = current(id) else { return }
        switch CodexAppServer.parse(data, pendingHooksListID: nil) {
        case .threadStarted(let thread, _, let ephemeral):
            // 첫 턴의 "제목 만들기" 스레드는 전달 주소가 아니다(f-stage1 판정 5).
            guard !ephemeral, thread != threadID else { return }
            threadID = thread
            if !named, let threadName {
                named = true
                conn.send(CodexAppServer.setThreadName(id: requestID(), threadID: thread, name: threadName))
            }
            onThreadStarted?(thread)
        case .threadClosed(let thread):
            // TUI 가 떠난 옛 스레드는 60초 뒤에 내려온다 — 지금 스레드일 때만 뜻이 있다(판정 6).
            if thread == threadID { threadID = nil }
        case .response(let rid, false):
            NSLog("[Dure] Codex 페인 \(sessionID): 요청 \(rid) 이 실패했습니다")
        default:
            break
        }
    }

    private func connectionClosed(_ id: ObjectIdentifier) {
        guard current(id) != nil else { return }
        // 서버가 끊었다. 서버 종료는 프로세스 종료로 따로 들어온다 — 여기서 페인을 끝내지 않는다.
        NSLog("[Dure] Codex 페인 \(sessionID): app-server 연결이 끊겼습니다")
        connection = nil
    }

    /// 서버가 먼저 끝나면 TUI 는 "Reconnecting…" 으로 남는다 — 스토어가 페인을 끝내게 알린다.
    private func serverDidExit(_ status: Int32) {
        guard !stopped, !serverExited else { return }
        serverExited = true
        handle = nil
        connection?.cancel()
        connection = nil
        fail("Codex 서버가 끝났습니다(종료 코드 \(status)) — 로그: \(paths.log)")
        onServerExit?()
    }

    /// 처음 이유만 남긴다. 표식은 TUI 스크립트가 `cat` 하고 끝난다(원자적 쓰기 — 반쯤 쓴 글을 읽지 않게).
    private func fail(_ reason: String) {
        if failure == nil { failure = reason }
        NSLog("[Dure] Codex 페인 \(sessionID): \(reason)")
        try? (reason + "\n").write(toFile: paths.failMarker, atomically: true, encoding: .utf8)
    }

    private static func seconds(_ t: TimeInterval) -> String {
        t == t.rounded() ? String(Int(t)) : String(t)
    }

    // MARK: - 파일 · 기본 구현

    /// 경로가 (링크를 따라) 유닉스 소켓인가. TUI 스크립트의 `[ -S … ]` 와 같은 판정.
    nonisolated static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    /// 서버는 짧은 경로도 `/private/tmp/codex-daemon-501/<hash>` 로의 링크로 만든다 — 링크와, 대상이 소켓이면 대상도 지운다.
    nonisolated static func removeSocket(_ path: String) {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let target = dest.hasPrefix("/") ? dest
                : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
            if isSocket(target) { unlink(target) }
        }
        unlink(path)
    }

    /// `codex --version` — GUI 앱은 PATH 가 비어 `zsh -ilc`. `.zshrc` 출력이 섞이므로 표지 뒤만 읽는다. 없거나 실패면 nil.
    nonisolated static func liveVersionOutput() async -> String? {
        let script = "unset DURE_SESSION DURE_AGENT_KIND; printf '%s\\n' \(CommandOutput.marker); codex --version"
        let r = await LiveCommandRunner().run(script, timeout: versionTimeout)
        guard r.status == 0, !r.timedOut else { return nil }
        return CommandOutput.afterMarker(r.stdout)
    }
}

// MARK: - 실제 프로세스

/// `/bin/zsh -ilc <서버 스크립트>`(nvm 의 PATH). 출력은 로그 파일로. 스크립트가 `exec codex` 라 루트 pid 는
/// npm 래퍼(node)이고 실제 서버는 그 자식이다 — 그래서 트리째 신호를 보낸다.
nonisolated struct LiveCodexProcessLauncher: CodexProcessLaunching {
    func launch(script: String, logPath: String,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> CodexProcessHandle {
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let log = FileHandle(forWritingAtPath: logPath) else { throw CocoaError(.fileWriteNoPermission) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", script]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { proc in
            try? log.close()
            onExit(proc.terminationStatus)
        }
        do { try p.run() } catch {
            try? log.close()
            throw error
        }
        return LiveCodexProcessHandle(process: p)
    }
}

nonisolated final class LiveCodexProcessHandle: CodexProcessHandle, @unchecked Sendable {
    private let process: Process
    /// SIGTERM 뒤 이만큼 기다려도 살아 있으면 SIGKILL.
    static let grace: TimeInterval = 3

    init(process: Process) { self.process = process }

    func terminate() {
        let p = process
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        LiveCommandRunner.killTree(pid, SIGTERM)
        // 루트가 아직 살아 있을 때만 다시 모아 죽인다 — 끝난 pid 를 다시 쓰는 남의 프로세스를 건드리지 않게.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.grace) {
            if p.isRunning { LiveCommandRunner.killTree(pid, SIGKILL) }
        }
    }
}
