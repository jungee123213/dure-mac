import Foundation
import Darwin

/// 단계 4 — 페인 하나의 MCP 소켓. `nc -U` 가 붙어 줄 단위 JSON-RPC 를 주고받는다.
///
/// **`nonisolated` 인 이유** — accept · read · write 가 소켓 큐에서 돈다. 메인에서 하면 `nc` 가 붙을 때마다 UI 가 멈춘다.
/// 그래서 이 파일은 MainActor 타입을 하나도 참조하지 않는다. 뜻(툴)은 `responder` 가 메인으로 넘겨 처리한다.
/// Network.framework 대신 POSIX 를 쓰는 이유는 이 프로젝트가 이미 `DispatchSource` 로 vnode 를 감시하고 있어
/// 같은 패턴이고, 유닉스 소켓 + chmod 0600 이 두 줄로 끝나서다.
nonisolated final class MCPServer {

    typealias Responder = @Sendable (String, @escaping @Sendable (String?) -> Void) -> Void

    let path: String
    private let responder: Responder
    private let queue = DispatchQueue(label: "dure.mcp.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    /// 지금 `queue` 위에 있는지 알아보는 표식. `stop()` 이 큐 위에서 불리면(응답 콜백 안 · 큐 위에서 놓인 마지막
    /// 참조의 `deinit`) `queue.sync` 가 재진입으로 프로세스를 죽인다. 그때는 바로 정리한다.
    private let onQueueKey = DispatchSpecificKey<Bool>()

    enum Problem: Error { case socket(Int32), bind(Int32), listen(Int32) }

    init(path: String, responder: @escaping Responder) {
        self.path = path
        self.responder = responder
        queue.setSpecific(key: onQueueKey, value: true)
    }

    /// 주인(단계 4 연결 작업)은 놓기 전에 메인에서 `stop()` 을 직접 부르는 게 원칙이다. 그래도 어느 스레드에서
    /// 마지막 참조가 놓이든 안전하도록 `stop()` 이 큐 위 여부를 스스로 가린다.
    deinit { stop() }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Problem.socket(errno) }
        // 지난번 앱이 남긴 소켓 파일이 있으면 bind 가 EADDRINUSE 로 실패한다.
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // 크기는 미리 재 둔다. 포인터를 쥔 채 `addr.sun_path` 를 다시 읽으면 배타적 접근 위반(컴파일 에러)이다.
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let ok = path.withCString { src -> Bool in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: cap) { p in
                    let n = strlen(src)
                    guard n < cap else { return false }
                    strncpy(p, src, n + 1)
                    return true
                }
            }
        }
        guard ok else { close(fd); throw Problem.bind(ENAMETOOLONG) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Problem.bind(e) }
        // 권한이 담긴 통로라 소유자만.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); unlink(path); throw Problem.listen(e) }
        Self.noSigPipe(fd)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        // fd 는 취소가 끝난 뒤에 닫는다. 먼저 닫으면 그 번호를 다음 accept 가 받아 가는 사이에
        // libdispatch 가 옛 등록을 걷어 내며 새 fd 를 건드릴 수 있다.
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
    }

    func stop() {
        if DispatchQueue.getSpecific(key: onQueueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        for (_, c) in connections { c.close() }
        connections.removeAll()
        guard listenFD >= 0 else { return }
        // listen fd 는 취소 핸들러가 닫는다. 소켓 파일은 기다리지 않고 지금 지운다 — 새 `nc` 가 붙지 못하게.
        if let src = acceptSource { src.cancel() } else { close(listenFD) }
        acceptSource = nil
        listenFD = -1
        unlink(path)
    }

    /// 상대(`nc`)가 사라진 소켓에 쓰면 기본 동작이 SIGPIPE 로 **앱 전체 종료**다. 소켓 단위로 꺼서
    /// write 가 EPIPE 를 돌려주게 한다. 프로세스 전역 `signal(SIGPIPE, SIG_IGN)` 은 다른 코드까지 바꿔서 피한다.
    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        Self.noSigPipe(fd)
        let conn = Connection(fd: fd, queue: queue, responder: responder) { [weak self] fd in
            self?.connections[fd] = nil
        }
        connections[fd] = conn
        conn.resume()
    }

    /// 연결 하나. 바이트를 모아 줄로 자르고, 응답은 **이 연결의 fd 로만** 쓴다.
    // 가변 상태는 전부 `queue` 안에서만 만진다 — 큐가 동기화라 @unchecked 다.
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let queue: DispatchQueue
        private let responder: Responder
        private let onClose: (Int32) -> Void
        private var buffer = Data()
        private var source: DispatchSourceRead?
        private var closed = false

        init(fd: Int32, queue: DispatchQueue, responder: @escaping Responder, onClose: @escaping (Int32) -> Void) {
            self.fd = fd; self.queue = queue; self.responder = responder; self.onClose = onClose
        }

        func resume() {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readSome() }
            // fd 는 취소가 끝난 뒤에 닫는다 (listen fd 와 같은 이유). self 를 잡지 않아 해제를 막지 않는다.
            let fd = self.fd
            src.setCancelHandler { Darwin.close(fd) }
            src.resume()
            source = src
        }

        private func readSome() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { close(); return }   // 0 = EOF, <0 = 에러. 둘 다 끝.
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                let fd = self.fd
                let queue = self.queue
                responder(line) { [weak self] reply in
                    guard let reply else { return }
                    // 응답은 어느 스레드에서 와도 소켓 큐에서 순서대로 쓴다.
                    queue.async {
                        guard let self, !self.closed else { return }
                        let data = Data((reply + "\n").utf8)
                        // 쓰기 제한 — 응답 하나에 합계 2초. 상대(`nc`)가 붙어 있지만 읽지 않으면 버퍼가 찬 write 가
                        // 영원히 막히고, 이 큐는 직렬이라 **모든** 페인의 accept · read · 응답이 같이 멈춘다.
                        // `SO_SNDTIMEO` 는 write 한 번마다의 제한이라 쓰기 전마다 남은 시간으로 다시 건다(Inbox 와 같은 이유).
                        // 시간이 다 되면 아래 실패 경로가 그 연결을 닫는다.
                        let deadline = Date().addingTimeInterval(Inbox.sendTimeout)
                        let ok = data.withUnsafeBytes { p -> Bool in
                            var off = 0
                            while off < data.count {
                                let left = deadline.timeIntervalSinceNow
                                if left <= 0 { return false }
                                var tv = timeval(tv_sec: Int(left), tv_usec: Int32((left - left.rounded(.down)) * 1_000_000))
                                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                                let w = write(fd, p.baseAddress! + off, data.count - off)
                                if w < 0 && errno == EINTR { continue }
                                if w <= 0 { return false }   // EPIPE(상대가 사라졌다) · EAGAIN(쓰기 제한) 등
                                off += w
                            }
                            return true
                        }
                        if !ok { self.close() }
                    }
                }
            }
        }

        func close() {
            guard !closed else { return }
            // `closed` 와 `onClose` 는 바로 — 늦게 온 응답은 즉시 버려진다. fd 자체는 취소 핸들러가 닫는다.
            closed = true
            if let src = source { src.cancel() } else { Darwin.close(fd) }
            source = nil
            onClose(fd)
        }
    }
}
