import Darwin
import Foundation

/// 2단계 — Codex 페인에 메시지를 넣는 길. `codex queue --remote unix://<서버 소켓> --thread <스레드 id> --message <글>`.
///
/// 셸을 거치지 않는다(argv) — 글에 따옴표 · `$` · 줄바꿈이 있어도 한 원소로 간다. `turn/start` 는 쓰지 않는다
/// (턴 중이면 그 턴에 끼어든다, 실측). 실패는 전부 종료 1 · stderr 한 줄이다(Task 1 실측 4절):
/// 소켓 없음 "failed to connect …", 틀린 UUID "… no rollout found …", UUID 아닌 이름 "No active session found …".
///
/// **종료 0 이 전달을 보장하지 않는다** — 중단된 턴(승인 거절 포함) 뒤에는 큐가 멈춰 0 인데 턴이 안 시작한다.
/// 이 타입은 종료 코드만 본다. 멈춘 큐 깨우기는 Task 4.
///
/// `Dispatcher` 가 메인에서 동기로 부른다(인박스와 같은 결) — 시간 한도(기본 3초)를 넘기면 트리째 죽이고 던진다.
nonisolated struct CodexQueueSender {

    enum Problem: Error, Equatable {
        /// `codex` 경로 · 로그인 PATH 를 아직 못 구했다(`CodexToolchainResolver`). 재시도 횟수에 든다.
        case codexNotResolved
        /// 0 이 아닌 종료. stderr 한 줄(앞뒤 공백 뺌).
        case exit(Int32, String)
        case timedOut
    }

    static let defaultTimeout: TimeInterval = 3

    let codexPath: String?
    let environment: [String: String]
    let timeout: TimeInterval
    let runner: ArgvRunning

    init(codexPath: String?, environment: [String: String], timeout: TimeInterval = CodexQueueSender.defaultTimeout,
         runner: ArgvRunning = LiveArgvRunner()) {
        self.codexPath = codexPath
        self.environment = environment
        self.timeout = timeout
        self.runner = runner
    }

    static func arguments(_ content: String, socket: String, thread: String) -> [String] {
        ["queue", "--remote", "unix://\(socket)", "--thread", thread, "--message", content]
    }

    func send(_ content: String, socket: String, thread: String) throws {
        guard let codexPath else { throw Problem.codexNotResolved }
        let r = runner.run(executable: codexPath, arguments: Self.arguments(content, socket: socket, thread: thread),
                           environment: environment, timeout: timeout)
        if r.timedOut { throw Problem.timedOut }
        guard r.status == 0 else {
            throw Problem.exit(r.status, r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 하위 프로세스 환경 — 앱 환경에 PATH 만 로그인 셸 것으로 바꾼다. `codex` 는 `#!/usr/bin/env node` 라
    /// 절대 경로로 불러도 node 가 PATH 에 있어야 한다(GUI 앱 PATH 에는 없다). 두레 페인 안에서 두레를 띄운 경우에 대비해
    /// 두레 표식은 뺀다(`CodexHookInventory` 와 같은 처리). `--remote` 면 큐는 서버 home 에 쌓이므로 CODEX_HOME 은 상관없다(실측).
    static func environment(loginPath: String,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = loginPath
        env["DURE_SESSION"] = nil
        env["DURE_AGENT_KIND"] = nil
        return env
    }
}

// MARK: - 셸 없이 실행

nonisolated struct ArgvResult: Equatable, Sendable {
    var status: Int32
    var stderr: String
    var timedOut: Bool
}

/// 실행 파일을 argv 그대로, 시간 한도 안에서 **동기로** 돌린다. 테스트는 가짜를 넣는다 — codex 를 띄우지 않게.
nonisolated protocol ArgvRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> ArgvResult
}

/// `LiveCommandRunner` 와 달리 `zsh -ilc` 를 거치지 않는다 — 셸 기동 300ms 를 메인에서 매번 쓰지 않으려고(실측 31ms 대 300ms).
/// 시간이 넘으면 트리째 TERM, 짧은 유예 뒤 KILL. 유예를 짧게 두는 이유는 메인에서 불리기 때문이다(한도 + 약 0.5초).
///
/// **메인에서 불린다 — 런루프를 돌리는 것은 아무것도 부르지 않는다**(리뷰 Important). `Process.waitUntilExit()` 는
/// 현재 런루프를 돌려 타이머 · 입력 소스를 불러 버리고, 그러면 전달 한가운데 `Dispatcher` 가 다시 들어와 같은 배분을
/// 두 번 보내거나 시도 횟수를 두 번 올린다. 그래서 자손 목록도 `pgrep`(하위 프로세스 + `waitUntilExit`)인
/// `LiveCommandRunner.descendants` 가 아니라 libproc 으로 구하고, 기다림은 세마포어만 쓴다.
nonisolated struct LiveArgvRunner: ArgvRunning {
    var grace: TimeInterval = 0.2

    /// 직계 자식 pid — libproc `proc_listchildpids`. 하위 프로세스도 런루프도 쓰지 않는다.
    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 32
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let n = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
            }
            guard n > 0 else { return [] }
            // 꽉 찼으면 잘렸을 수 있다 — 넓혀 다시 묻는다.
            if Int(n) < capacity || capacity >= 4096 { return Array(buffer.prefix(Int(n))).filter { $0 > 0 } }
            capacity *= 4
        }
    }

    /// 자손 전부(깊이 우선, 부모가 앞). 순환 · pid 재사용에 대비해 본 것은 다시 걷지 않는다.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var seen: Set<pid_t> = [pid]
        var out: [pid_t] = []
        func walk(_ p: pid_t) {
            for c in children(of: p) where seen.insert(c).inserted {
                out.append(c)
                walk(c)
            }
        }
        walk(pid)
        return out
    }

    /// 자식부터 신호를 보낸다 — 부모를 먼저 죽이면 자식이 launchd 로 넘어가 루트에서 못 찾는다.
    private static func signal(_ pids: [pid_t], _ sig: Int32) {
        for pid in pids.reversed() where kill(pid, 0) == 0 { kill(pid, sig) }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false
        func append(_ d: Data) {
            lock.withLock {
                if d.isEmpty { eof = true } else if data.count < 64 << 10 { data.append(d.prefix((64 << 10) - data.count)) }
            }
        }
        var snapshot: (data: Data, eof: Bool) { lock.withLock { (data, eof) } }
    }

    func run(executable: String, arguments: [String], environment: [String: String],
             timeout: TimeInterval) -> ArgvResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let sink = Sink()
        err.fileHandleForReading.readabilityHandler = { sink.append($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            err.fileHandleForReading.readabilityHandler = nil
            return ArgvResult(status: -1, stderr: "\(error)", timedOut: false)
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            let root = p.processIdentifier
            // TERM 시점의 자손을 기억해 둔다 — 루트가 먼저 죽으면 고아가 된 자손은 루트에서 다시 못 찾는다.
            var known = Self.descendants(of: root)
            Self.signal([root] + known, SIGTERM)
            if exited.wait(timeout: .now() + grace) == .timedOut {
                known += Self.descendants(of: root)
                Self.signal([root] + known, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
            // 루트가 죽은 뒤에 — 기억해 둔 자손들 밑에 그 사이 생긴 손자까지 다시 모아 남은 것을 전부 KILL 한다.
            known += known.flatMap { Self.descendants(of: $0) }
            for pid in Set(known) where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        // stderr 는 한 줄이다. 자손이 파이프를 쥐고 있으면 EOF 가 안 오므로 잠깐만 기다린다.
        let deadline = Date().addingTimeInterval(0.1)
        while Date() < deadline, !sink.snapshot.eof { Thread.sleep(forTimeInterval: 0.005) }
        err.fileHandleForReading.readabilityHandler = nil
        return ArgvResult(status: p.isRunning ? -9 : p.terminationStatus,
                          stderr: String(decoding: sink.snapshot.data, as: UTF8.self), timedOut: timedOut)
    }
}

// MARK: - codex 경로 · 로그인 PATH

/// 로그인 셸에서 구한 `codex` 절대 경로와 `$PATH`.
nonisolated struct CodexToolchain: Equatable, Sendable {
    var codexPath: String
    var path: String

    /// `whence -p` 는 zsh 의 `command -v` 에서 별칭 · 함수를 뺀 판이다 — 실행 파일 경로만 돌려준다.
    /// `.zshrc` 출력이 앞에 섞이므로 표지 뒤만 읽는다(`CommandOutput.marker`).
    static let script = "printf '%s\\n%s\\n%s\\n' \(CommandOutput.marker) \"$(whence -p codex)\" \"$PATH\""

    static func parse(_ stdout: Data) -> CodexToolchain? {
        guard let tail = CommandOutput.afterMarker(stdout) else { return nil }
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        let codex = lines[0].trimmingCharacters(in: .whitespaces)
        let path = lines[1].trimmingCharacters(in: .whitespaces)
        guard codex.hasPrefix("/"), !path.isEmpty else { return nil }
        return CodexToolchain(codexPath: codex, path: path)
    }

    /// `zsh -ilc` 한 번(약 300ms). 메인에서 부르지 않는다.
    static func resolveLive() -> CodexToolchain? {
        let r = LiveCommandRunner.runBlocking(script, timeout: 10, grace: 1)
        guard !r.timedOut, r.status == 0, let t = parse(r.stdout) else {
            NSLog("[Dure] codex 경로를 못 구했습니다 (종료 \(r.status)\(r.timedOut ? ", 시간 초과" : "")): "
                  + CommandOutput.tail(r.stderr, max: 300))
            return nil
        }
        return t
    }
}

/// 앱 세션마다 한 번 `zsh -ilc` 로 `codex` 경로와 PATH 를 구해 둔다(메인 밖). 전달은 캐시만 읽는다 —
/// 아직 없으면 `CodexQueueSender` 가 던지고 그 배분은 재시도 횟수에 든다. 구하기에 실패하면 캐시하지 않아 다음 `start()` 에 다시 구한다.
nonisolated final class CodexToolchainResolver: @unchecked Sendable {
    let queue: DispatchQueue
    private let resolve: @Sendable () -> CodexToolchain?
    private let lock = NSLock()
    private var cached: CodexToolchain?
    private var running = false

    init(queue: DispatchQueue = .global(qos: .utility),
         resolve: @escaping @Sendable () -> CodexToolchain? = CodexToolchain.resolveLive) {
        self.queue = queue
        self.resolve = resolve
    }

    var current: CodexToolchain? { lock.withLock { cached } }

    /// 이미 구했거나 구하는 중이면 아무것도 안 한다.
    func start() {
        let go = lock.withLock { () -> Bool in
            guard cached == nil, !running else { return false }
            running = true
            return true
        }
        guard go else { return }
        queue.async { [self] in
            let t = resolve()
            lock.withLock {
                if let t { cached = t }
                running = false
            }
        }
    }
}
