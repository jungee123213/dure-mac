import Darwin
import Foundation

/// 사용자 Codex 의 훅 목록 — 진짜 home 으로 일회용 stdio `codex app-server` 를 띄워 `hooks/list` 를 묻는다.
///
/// 읽기만 한다(실측 M1: config · hooks.json · rules 변화 없음). 페인 서버가 끌 플러그인과 옮길 사용자 훅을 여기서 정한다.
/// 실패하거나 5초를 넘기면 빈 배열 — 페인 시작을 막지 않는다(훅을 못 옮길 뿐이다).
/// stdio 판은 WebSocket 이 아니라 줄마다 JSON 하나다.
nonisolated enum CodexHookInventory {

    static let timeout: TimeInterval = 5

    /// GUI 앱은 PATH 가 비어 있어 `zsh -ilc` 로 띄운다(`Spawn` 과 같은 이유). CODEX_HOME 은 사용자 셸이 정한 그대로(진짜 home).
    /// 두레 페인 안에서 두레를 띄운 경우에 대비해 두레 표식만 지운다.
    static let defaultScript = "unset DURE_SESSION DURE_AGENT_KIND; exec codex app-server -c check_for_update_on_startup=false"

    static func load(cwd: String) async -> [CodexAppServer.HookEntry] {
        await load(cwd: cwd, executable: "/bin/zsh", arguments: ["-ilc", defaultScript], timeout: timeout)
    }

    /// 테스트는 진짜 codex 대신 가짜 스크립트를 넣는다.
    static func load(cwd: String, executable: String, arguments: [String],
                     timeout: TimeInterval) async -> [CodexAppServer.HookEntry] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(cwd: cwd, executable: executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static let initializeID = 1
    private static let hooksListID = 2

    /// 줄 버퍼와 결과. 읽기 핸들러(별도 스레드)와 기다리는 쪽이 같이 본다.
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var result: [CodexAppServer.HookEntry]?
        private var failure: String?
        private var initialized = false
        let done = DispatchSemaphore(value: 0)
        let input: FileHandle
        let cwd: String

        init(input: FileHandle, cwd: String) {
            self.input = input
            self.cwd = cwd
        }

        var outcome: (entries: [CodexAppServer.HookEntry]?, failure: String?) { lock.withLock { (result, failure) } }

        func fail(_ why: String) {
            let first = lock.withLock { () -> Bool in
                guard result == nil, failure == nil else { return false }
                failure = why
                return true
            }
            if first { done.signal() }
        }

        func feed(_ data: Data) {
            guard !data.isEmpty else { fail("서버가 결과 없이 끝났습니다"); return }
            let lines: [Data] = lock.withLock {
                buffer.append(data)
                var out: [Data] = []
                while let nl = buffer.firstIndex(of: 0x0A) {
                    out.append(Data(buffer[buffer.startIndex..<nl]))
                    buffer = Data(buffer[buffer.index(after: nl)...])
                }
                return out
            }
            // `.zshrc` 출력이 앞에 섞인다 — JSON 이 아닌 줄은 parse 가 nil 이라 건너뛴다.
            for line in lines {
                switch CodexAppServer.parse(line, pendingHooksListID: CodexHookInventory.hooksListID) {
                case .response(let id, let ok) where id == CodexHookInventory.initializeID:
                    guard ok else { fail("initialize 실패"); return }
                    let first = lock.withLock { () -> Bool in
                        defer { initialized = true }
                        return !initialized
                    }
                    if first {
                        write(CodexAppServer.initialized())
                        write(CodexAppServer.hooksList(id: CodexHookInventory.hooksListID, cwd: cwd))
                    }
                case .response(let id, false) where id == CodexHookInventory.hooksListID:
                    fail("hooks/list 실패")
                case .hooksListResult(_, let entries):
                    let first = lock.withLock { () -> Bool in
                        guard result == nil, failure == nil else { return false }
                        result = entries
                        return true
                    }
                    if first { done.signal() }
                default:
                    break
                }
            }
        }

        func write(_ message: Data) {
            do { try input.write(contentsOf: message + Data([0x0A])) } catch { fail("stdin 쓰기 실패: \(error)") }
        }
    }

    private static func runBlocking(cwd: String, executable: String, arguments: [String],
                                    timeout: TimeInterval) -> [CodexAppServer.HookEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        // 서버가 먼저 죽은 뒤 쓰면 SIGPIPE 로 앱이 죽는다 — 이 파이프만 SIGPIPE 를 끈다.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let session = Session(input: stdin.fileHandleForWriting, cwd: cwd)
        stdout.fileHandleForReading.readabilityHandler = { session.feed($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        do { try p.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            NSLog("Dure: Codex 훅 목록 — 서버를 못 띄웠습니다: \(error)")
            return []
        }
        session.write(CodexAppServer.initialize(id: initializeID))

        if session.done.wait(timeout: .now() + timeout) == .timedOut {
            session.fail("\(timeout)초 안에 답이 없습니다")
        }
        stdout.fileHandleForReading.readabilityHandler = nil

        // 끝내기 — stdin 을 닫으면 stdio 서버는 스스로 끝난다. 안 끝나면 트리째 TERM → KILL.
        try? stdin.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 0.5) == .timedOut {
            let tree = LiveCommandRunner.descendants(of: p.processIdentifier)
            LiveCommandRunner.killTree(p.processIdentifier, SIGTERM)
            if exited.wait(timeout: .now() + 1) == .timedOut {
                LiveCommandRunner.killTree(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }

        let outcome = session.outcome
        if let entries = outcome.entries { return entries }
        NSLog("Dure: Codex 훅 목록을 못 읽었습니다 — \(outcome.failure ?? "알 수 없음"). 사용자 훅을 옮기지 않고 시작합니다")
        return []
    }
}
