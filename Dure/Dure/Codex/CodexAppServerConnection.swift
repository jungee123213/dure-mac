import Darwin
import Foundation
import Network

/// 페인 전용 `codex app-server --listen unix://<sock>` 에 붙는 WebSocket 클라이언트 하나.
///
/// `NWProtocolWebSocket` 은 `.unix` 끝점에서 핸드셰이크를 한 바이트도 안 보낸다(실측 M6). 그래서
/// `NWConnection(.unix, .tcp)` 원시 연결 위에 HTTP Upgrade 와 RFC 6455 프레이밍을 손으로 얹는다(`CodexWebSocketFrame`).
/// 상태는 전부 자기 직렬 큐에서만 만진다. 콜백도 그 큐에서 부른다 — 메인으로는 호출 쪽이 넘어간다.
nonisolated final class CodexAppServerConnection: @unchecked Sendable {

    private let socketPath: String
    private let queue = DispatchQueue(label: "dure.codex.app-server")

    // 아래는 queue 에서만
    private var connection: NWConnection?
    private var key = ""
    private var handshake = Data()
    private var upgraded = false
    private var reader = CodexWebSocketReader()
    private var pending: [Data] = []
    private var finished = false
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        connection?.cancel()
    }

    /// 메시지(JSON-RPC 하나)마다 `onMessage`, 연결이 끊기면 한 번 `onClose`. `cancel()` 로 끊으면 `onClose` 는 부르지 않는다.
    func start(onMessage: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard connection == nil, !finished else { return }
            self.onMessage = onMessage
            self.onClose = onClose
            // 서버는 긴 소켓 경로를 링크로 만든다 — 실제 경로로 붙는다.
            let path = Self.resolved(socketPath)
            let conn = NWConnection(to: .unix(path: path), using: .tcp)
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.sendUpgrade()
                case .failed(let error):
                    NSLog("Dure: Codex app-server 연결 실패 \(path): \(error)")
                    self.finish()
                case .waiting(let error):
                    // 유닉스 소켓에서 waiting 은 소켓이 없거나 서버가 받지 않는 것 — 기다려도 안 붙는다.
                    NSLog("Dure: Codex app-server 연결 대기 \(path): \(error)")
                    self.finish()
                case .cancelled: self.finish()
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// 핸드셰이크 전에 보내면 쌓아 뒀다가 업그레이드 직후 순서대로 보낸다.
    func send(_ data: Data) {
        queue.async { [self] in
            guard !finished else { return }
            if upgraded { write(CodexWebSocketFrame.encode(opcode: 0x1, payload: data)) } else { pending.append(data) }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            onMessage = nil
            onClose = nil
            close(code: Data([0x03, 0xe8]))   // 1000 정상 종료
        }
    }

    // MARK: - queue 안

    private func sendUpgrade() {
        key = CodexWebSocketFrame.randomKey()
        write(CodexWebSocketFrame.upgradeRequest(key: key))
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if self.finished { return }
            if done || error != nil {
                if let error { NSLog("Dure: Codex app-server 수신 오류: \(error)") }
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        var frames = data
        if !upgraded {
            handshake.append(data)
            switch CodexWebSocketFrame.parseHandshake(handshake, key: key) {
            case .needMore:
                if handshake.count > 64 << 10 { NSLog("Dure: Codex app-server 핸드셰이크 응답이 너무 깁니다"); finish() }
                return
            case .failed(let why):
                NSLog("Dure: Codex app-server 핸드셰이크 실패: \(why)")
                finish()
                return
            case .upgraded(let consumed):
                upgraded = true
                frames = Data(handshake.dropFirst(consumed))
                handshake = Data()
                for p in pending { write(CodexWebSocketFrame.encode(opcode: 0x1, payload: p)) }
                pending = []
            }
        }
        for event in reader.feed(frames) {
            switch event {
            case .message(let m): onMessage?(m)
            case .ping(let p): write(CodexWebSocketFrame.encode(opcode: 0xA, payload: p))
            case .close:
                finish(code: Data())   // 받은 close 에 답하고 끊는다
            case .invalid:
                NSLog("Dure: Codex app-server 프레임이 잘못됐습니다")
                finish()
            }
            if finished { return }
        }
    }

    private func write(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error { NSLog("Dure: Codex app-server 보내기 실패: \(error)") }
        })
    }

    /// 서버 쪽 사정으로 끝났다 — `onClose` 를 한 번 부른다. `code` 가 있으면 close 프레임을 보내고 끊는다.
    private func finish(code: Data? = nil) {
        guard !finished else { return }
        finished = true
        let callback = onClose
        onMessage = nil
        onClose = nil
        if let code { close(code: code) } else { connection?.cancel(); connection = nil }
        callback?()
    }

    /// close 프레임이 나간 뒤에 연결을 닫는다 — 바로 cancel 하면 프레임이 버려진다. 보내기 오류는 무시한다(끊는 중이다).
    private func close(code: Data) {
        guard let conn = connection else { return }
        connection = nil
        guard upgraded else { conn.cancel(); return }
        conn.send(content: CodexWebSocketFrame.encode(opcode: 0x8, payload: code),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func resolved(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }
}
