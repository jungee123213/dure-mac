// Dure/Dure/Observer/CommandRunner.swift
import Darwin
import Foundation

nonisolated struct CommandResult: Equatable, Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    /// `cancelAll()` 로 죽였다 — 앱 종료. 실패가 아니라 "끝나지 않음" 이라 호출 쪽은 기록을 남기지 않는다.
    var cancelled = false
}

/// `claude -p` · `gh` 실행. 테스트는 가짜를 넣는다 — 진짜 `claude` 는 돈이 들고 결과가 매번 다르다.
nonisolated protocol CommandRunning: Sendable {
    func run(_ script: String, timeout: TimeInterval) async -> CommandResult
    /// 돌고 있는 것을 트리째 죽인다. 앱 종료 때 — 평가 중인 `claude -p` 가 고아로 남아 한도를 쓰지 않게.
    func cancelAll()
}

extension CommandRunning {
    func cancelAll() {}
}

/// 지금 돌고 있는 루트 pid. 러너는 값 타입이라 복사돼도 같은 장부를 보도록 참조로 둔다.
nonisolated final class ProcessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var killed: Set<pid_t> = []

    func add(_ pid: pid_t) { lock.withLock { _ = pids.insert(pid) } }
    /// 지우면서 cancelAll 로 죽었는지 돌려준다.
    func remove(_ pid: pid_t) -> Bool { lock.withLock { pids.remove(pid); return killed.remove(pid) != nil } }
    var running: Set<pid_t> { lock.withLock { pids } }

    func killAll() {
        let targets = lock.withLock { killed.formUnion(pids); return pids }
        for pid in targets { LiveCommandRunner.killTree(pid, SIGKILL) }
    }
}

/// **`zsh -ilc` 다**(GUI 앱은 PATH 가 비어 `claude` · `gh` 를 못 찾는다, `Spawn` 과 같은 이유).
/// 시간 한도는 **보장**한다(리뷰 P1-H): SIGTERM 을 무시하는 프로세스는 트리째 SIGKILL, 파이프를 쥔 손자는 기다리지 않는다.
nonisolated struct LiveCommandRunner: CommandRunning {
    var grace: TimeInterval = 5
    let tracker = ProcessTracker()

    func run(_ script: String, timeout: TimeInterval) async -> CommandResult {
        let grace = grace, tracker = tracker
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Self.runBlocking(script, timeout: timeout, grace: grace, tracker: tracker))
            }
        }
    }

    /// 앱 종료 직전이라 유예를 주지 않는다 — 평가는 읽기 전용이고, 끊긴 실행은 다음 실행 때 `recover` 가 다시 큐에 넣는다.
    func cancelAll() { tracker.killAll() }

    /// 파이프에서 읽은 것. 8MB 를 넘으면 버린다(평가 출력이 그렇게 클 일은 없다 — 무한 출력에 메모리를 내주지 않는다).
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false
        func append(_ d: Data) {
            lock.withLock {
                if d.isEmpty { eof = true } else if data.count < 8 << 20 { data.append(d.prefix((8 << 20) - data.count)) }
            }
        }
        var snapshot: (data: Data, eof: Bool) { lock.withLock { (data, eof) } }
    }

    static func runBlocking(_ script: String, timeout: TimeInterval, grace: TimeInterval,
                            tracker: ProcessTracker? = nil) -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let o = Sink(), e = Sink()
        out.fileHandleForReading.readabilityHandler = { o.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { e.append($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: -1, stdout: Data(), stderr: Data("\(error)".utf8), timedOut: false)
        }
        tracker?.add(p.processIdentifier)
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // SIGTERM 시점의 자손을 기억해 둔다 — 루트가 먼저 죽으면 고아가 된 자손은 pgrep -P 로 다시 못 찾는다.
            var tree = descendants(of: p.processIdentifier)
            killTree(p.processIdentifier, SIGTERM)
            if exited.wait(timeout: .now() + grace) == .timedOut {
                killTree(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            // 루트가 TERM 에 죽어도 TERM 을 무시하는 자손은 남는다. 유예 뒤 살아 있는 것을 전부 SIGKILL 한다.
            if p.isRunning == false { tree += descendants(of: p.processIdentifier) }
            for pid in Set(tree) where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        // 종료 뒤 파이프 — 손자 프로세스가 쥐고 있으면 EOF 가 영영 안 온다. 1초까지만 기다린다.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, !(o.snapshot.eof && e.snapshot.eof) { Thread.sleep(forTimeInterval: 0.05) }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let cancelled = tracker?.remove(p.processIdentifier) ?? false
        return CommandResult(status: p.isRunning ? -9 : p.terminationStatus, stdout: o.snapshot.data,
                             stderr: e.snapshot.data, timedOut: timedOut, cancelled: cancelled)
    }

    /// 자손을 먼저 모은 뒤 죽인다 — 부모를 먼저 죽이면 자식이 고아가 돼 `pgrep -P` 로 못 찾는다.
    static func killTree(_ pid: pid_t, _ sig: Int32) {
        for d in descendants(of: pid).reversed() { kill(d, sig) }
        kill(pid, sig)
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let children = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        return children.flatMap { [$0] + descendants(of: $0) }
    }
}

nonisolated enum CommandOutput {
    /// `.zshrc` 출력이 stdout 에 섞인다 — `gh` 명령은 앞에 표지를 찍고 그 뒤만 읽는다.
    static let marker = "__DURE_OUT__"

    static func afterMarker(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        guard let r = s.range(of: marker + "\n", options: .backwards) else { return nil }
        return String(s[r.upperBound...])
    }

    static func tail(_ data: Data, max: Int = 2000) -> String {
        String(String(decoding: data, as: UTF8.self).suffix(max)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
