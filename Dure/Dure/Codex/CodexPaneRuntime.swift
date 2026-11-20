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
    /// 전달 뒤 이만큼 턴이 시작되지 않으면 멈춘 큐로 보고 `thread/queue/start` 를 보낸다(g-stage2 4절 — 정상은 10ms 안).
    nonisolated static let defaultNudgeDelay: TimeInterval = 5

    /// 주소 보충의 재료 — `thread/loaded/list` 의 id 하나를 `thread/read` 로 읽은 것.
    nonisolated struct LoadedThread: Equatable {
        let id: String
        let cwd: String?
        let ephemeral: Bool
        /// 서브에이전트 스레드면 부모 스레드 id(스키마 `parentThreadId`). 전달 주소가 아니다.
        var parentThreadID: String? = nil
    }

    /// 보충할 스레드 — 임시도 서브에이전트도 아니고 cwd 가 페인 cwd 인 스레드가 **하나뿐일 때만** 그 id.
    /// `/new` 뒤 약 60초는 옛 스레드도 같은 cwd 로 남는다(g-stage2 3절) — 둘이면 고르지 않고 다음 `thread/started` 를 기다린다.
    nonisolated static func adoptable(_ threads: [LoadedThread], cwd: String) -> String? {
        let target = normalizedPath(cwd)
        let matches = threads.filter { !$0.ephemeral && $0.parentThreadID == nil && $0.cwd.map(normalizedPath) == target }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// 끝 `/` · `.` · 링크(`/var` ↔ `/private/var`)를 맞춘다. 양쪽을 같은 함수로 거르므로 비교만 맞으면 된다.
    nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 실제 타이머 — 메인 큐에서 `delay` 뒤에 부른다.
    nonisolated static func mainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

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
    private let mcpSocket: String?
    private let nudgeDelay: TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    /// 지금 TUI 가 쓰는 스레드(= 훅 `session_id`). `/new` · `/clear` 마다 바뀐다. 임시(제목) 스레드는 잡지 않는다.
    private(set) var threadID: String?
    /// 두레가 배분을 넣을 주소 — 서버 소켓 + 지금 스레드. 스레드를 아직 모르면 nil(배분은 큐에 남는다).
    var address: PaneAddress? { threadID.map { .codex(socket: paths.socket, thread: $0) } }
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

    // 주소 보충 — initialize 응답 뒤 스레드를 모르면 thread/loaded/list → id 마다 thread/read.
    private var initializeID: Int?
    private var initialized = false
    private var pendingLoadedListID: Int?
    private var pendingReads: [Int: String] = [:]
    private var readThreads: [LoadedThread] = []
    private var readStatuses: [String: String] = [:]

    // 멈춘 큐 깨우기 — 지금 스레드의 마지막 상태(`thread/status/changed`), 깨울 스레드, 타이머 세대.
    private var threadStatus: String?
    private var nudgeThread: String?
    private var nudgeGeneration = 0

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
         shimPath: String? = nil,
         mcpSocket: String? = nil,
         nudgeDelay: TimeInterval = CodexPaneRuntime.defaultNudgeDelay,
         schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = CodexPaneRuntime.mainAfter) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.profile = profile
        self.paths = paths
        self.launcher = launcher
        self.threadName = threadName
        self.userCodexHome = userCodexHome
        self.versionOutput = versionOutput
        self.inventory = inventory
        self.mcpSocket = mcpSocket
        self.connect = connect
        self.socketReady = socketReady
        self.socketTimeout = socketTimeout
        self.nudgeDelay = nudgeDelay
        self.schedule = schedule
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
        nudgeThread = nil
        nudgeGeneration += 1
    }

    /// 스토어가 이 페인으로 전달(`codex queue`)에 성공한 직후 부른다. `codex queue` 의 종료 0 은 턴 시작을 보장하지 않는다 —
    /// 중단된 턴 뒤 큐가 멈춘다(g-stage2 4절). 그래서 `nudgeDelay` 안에 지금 스레드가 `active` 로 바뀌지 않으면
    /// 실험 API `thread/queue/start` 를 한 번 보낸다. 지금 턴이 도는 중(`active`)이면 그 턴이 끝난(`active` 가 아닌) 때부터 잰다 —
    /// 도는 턴에 큐를 끼워 넣지 않는다. 실패는 로그만(그 배분은 `delivered` 로 남고 사람이 본다).
    func nudgeQueue() {
        guard !stopped, connection != nil, let thread = threadID else { return }
        nudgeThread = thread
        nudgeGeneration += 1
        if threadStatus != "active" { armNudge() }
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
                                              disabledPlugins: disabled, mcpSocket: mcpSocket)

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
        let initID = requestID()
        initializeID = initID
        conn.send(CodexAppServer.initialize(id: initID))
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
        case .threadStarted(let thread, _, let ephemeral, let parent):
            // 첫 턴의 "제목 만들기" 스레드는 전달 주소가 아니다(f-stage1 판정 5). 서브에이전트 스레드(부모가 있는 것)도.
            guard !ephemeral, parent == nil, thread != threadID else { return }
            adopt(thread, status: nil, on: conn)
        case .threadStatus(let thread, let status):
            statusChanged(thread, to: status)
        case .threadClosed(let thread):
            // TUI 가 떠난 옛 스레드는 60초 뒤에 내려온다 — 지금 스레드일 때만 뜻이 있다(판정 6).
            if thread == threadID {
                threadID = nil
                threadStatus = nil
            }
            // 보충이 둘 중 하나를 못 골랐던 경우 — 옛 스레드가 내려가면 이제 하나뿐일 수 있다.
            if threadID == nil { recover(on: conn) }
        case .response(let rid, let ok) where rid == initializeID:
            initializeID = nil
            guard ok else {
                NSLog("[Dure] Codex 페인 \(sessionID): initialize 가 실패했습니다")
                return
            }
            initialized = true
            if threadID == nil { recover(on: conn) }
        case .loadedThreads(let rid, let ids) where rid == pendingLoadedListID:
            pendingLoadedListID = nil
            guard threadID == nil else { return }
            readThreads = []
            readStatuses = [:]
            for id in ids {
                let r = requestID()
                pendingReads[r] = id
                conn.send(CodexAppServer.readThread(id: r, threadID: id))
            }
            finishRecoveryIfDone(on: conn)
        case .threadRead(let rid, let thread, let cwd, let ephemeral, let status, let parent) where pendingReads[rid] != nil:
            pendingReads[rid] = nil
            readThreads.append(LoadedThread(id: thread, cwd: cwd, ephemeral: ephemeral, parentThreadID: parent))
            if let status { readStatuses[thread] = status }
            finishRecoveryIfDone(on: conn)
        case .response(let rid, let ok):
            // 보충 요청의 응답이면 성공이든 실패든 기다림에서 뺀다 — 모양이 어긋난 성공(`thread` 없는 thread/read ·
            // `data` 없는 loaded list)이 `.response(ok: true)` 로 오면 영영 안 빠져 보충이 막힌다(최종 리뷰 M1).
            if pendingReads.removeValue(forKey: rid) != nil {
                finishRecoveryIfDone(on: conn)          // 그 사이 내려간 스레드 · 못 읽은 스레드 — 빼고 판정한다
            } else if rid == pendingLoadedListID {
                pendingLoadedListID = nil
            }
            if !ok { NSLog("[Dure] Codex 페인 \(sessionID): 요청 \(rid) 이 실패했습니다") }
        default:
            break
        }
    }

    /// 새 스레드(`thread/started`)와 보충한 스레드가 같은 길로 간다 — 이름 붙이기 · 스토어 알림(큐 흘리기).
    private func adopt(_ thread: String, status: String?, on conn: any CodexServerConnecting) {
        threadID = thread
        threadStatus = status
        nudgeThread = nil                     // 옛 스레드의 배분은 SessionStart 규칙이 닫는다
        nudgeGeneration += 1
        if !named, let threadName {
            named = true
            conn.send(CodexAppServer.setThreadName(id: requestID(), threadID: thread, name: threadName))
        }
        onThreadStarted?(thread)
    }

    // MARK: - 주소 보충

    /// 두레가 TUI 보다 늦게 붙으면 `thread/started` 를 놓친다 — 서버에 올라와 있는 스레드에서 찾는다.
    private func recover(on conn: any CodexServerConnecting) {
        guard initialized, threadID == nil, pendingLoadedListID == nil, pendingReads.isEmpty else { return }
        let r = requestID()
        pendingLoadedListID = r
        conn.send(CodexAppServer.loadedThreads(id: r))
    }

    private func finishRecoveryIfDone(on conn: any CodexServerConnecting) {
        guard pendingLoadedListID == nil, pendingReads.isEmpty else { return }
        let threads = readThreads, statuses = readStatuses
        readThreads = []
        readStatuses = [:]
        // 그 사이 thread/started 가 왔으면 그것이 맞다.
        guard threadID == nil, !threads.isEmpty else { return }
        guard let thread = Self.adoptable(threads, cwd: cwd) else {
            NSLog("[Dure] Codex 페인 \(sessionID): 올라온 스레드 \(threads.count)개에서 주소를 고르지 못했습니다 — 다음 thread/started 를 기다립니다")
            return
        }
        NSLog("[Dure] Codex 페인 \(sessionID): 올라와 있던 스레드 \(thread) 를 주소로 씁니다")
        adopt(thread, status: statuses[thread], on: conn)
    }

    // MARK: - 멈춘 큐 깨우기

    private func statusChanged(_ thread: String, to status: String) {
        guard thread == threadID else { return }
        let was = threadStatus
        threadStatus = status
        guard nudgeThread == thread else { return }
        if status == "active" {
            // 새 턴이 시작됐다 — 큐가 돈다. (active → active 는 같은 턴의 플래그 변화라 아니다.)
            if was != "active" {
                nudgeThread = nil
                nudgeGeneration += 1
            }
        } else if was == "active" {
            // 턴이 끝났거나 끊겼다 — 넣어 둔 것이 지금부터 돌아야 한다.
            armNudge()
        }
    }

    private func armNudge() {
        nudgeGeneration += 1
        let generation = nudgeGeneration
        schedule(nudgeDelay) { [weak self] in self?.nudgeDue(generation) }
    }

    private func nudgeDue(_ generation: Int) {
        guard !stopped, generation == nudgeGeneration, let thread = nudgeThread, thread == threadID else { return }
        nudgeThread = nil
        guard let conn = connection else {
            NSLog("[Dure] Codex 페인 \(sessionID): 큐를 깨워야 하는데 app-server 연결이 없습니다")
            return
        }
        let r = requestID()
        conn.send(CodexAppServer.startQueue(id: r, threadID: thread))
        NSLog("[Dure] Codex 페인 \(sessionID): 전달 뒤 \(Self.seconds(nudgeDelay))초 안에 턴이 시작되지 않아 큐를 다시 돌립니다 — thread/queue/start \(thread) (요청 \(r))")
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
