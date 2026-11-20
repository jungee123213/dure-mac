import Foundation
import Darwin

/// 단계 4 — 앱이 페인(Claude Code 세션)에 메시지를 넣는 유일한 길. 설계 3-1절.
///
/// 문서상 인박스 소켓은 "세션 자신의 자식 프로세스" 용이지만 외부 프로세스가 써도 받는다(실측 2026-10-08).
/// 막히는 버전이 오면 **이 파일만** 바꿔 조율자의 직접 `SendMessage` 로 내린다(D-32).
/// `nonisolated` 인 이유는 connect 가 막힐 수 있어 메인 밖에서도 부르게 하려는 것이다. MainActor 타입을 참조하지 않는다.
nonisolated enum Inbox {

    static var defaultRegistry: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// pid 를 추적하지 않는다 — `SessionStart` 훅이 준 `session_id` 로 레지스트리를 찾는 쪽이 `exec` · 재시작에 안전하다.
    static func socketPath(forClaudeSession id: String, registry: URL = defaultRegistry) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: registry.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: registry.appendingPathComponent(name)),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  o["sessionId"] as? String == id,
                  let path = o["messagingSocketPath"] as? String else { continue }
            return path
        }
        return nil
    }

    /// 실측한 최소 프레임. auth 줄은 macOS 에서 선택이라 넣지 않는다. 발신자 이름 필드는 무시되므로 본문이 발신자를 적는다.
    static func frame(_ content: String) -> String {
        let o: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    enum Problem: Error { case noSocket, connect(Int32), write(Int32) }

    /// 메시지 하나를 쓰는 데 쓰는 최대 시간(초). 아래 `send` 참고.
    static let sendTimeout: TimeInterval = 2

    /// 남은 시간(초) → `SO_SNDTIMEO` 값. **절대 {0, 0} 을 돌려주지 않는다** — Darwin 에서 {0,0} 은 "무제한" 이라
    /// 1µs 미만이 남았을 때 그대로 넣으면 막지 않으려던 무한 블로킹이 다시 열린다. 최소 1µs 로 올린다.
    static func timeoutValue(remaining left: TimeInterval) -> timeval {
        let sec = max(0, Int(left))
        let usec = Int32((left - left.rounded(.down)) * 1_000_000)
        return timeval(tv_sec: sec, tv_usec: sec == 0 ? max(1, usec) : max(0, usec))
    }

    static func send(_ content: String, toSocket path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Problem.connect(errno) }
        defer { close(fd) }
        // 받는 쪽(claude)이 먼저 사라진 소켓에 쓰면 기본 동작이 SIGPIPE 로 앱 전체 종료다. 소켓 단위로 꺼서 EPIPE 로 받는다.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
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
        guard ok else { throw Problem.connect(ENAMETOOLONG) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard r == 0 else { throw Problem.connect(errno) }
        let data = Data(frame(content).utf8)
        // 쓰기 제한 — 메시지 하나에 **합계** 2초. 받는 쪽이 살아 있지만 읽지 않으면(멈춘 claude) 버퍼가 차는 순간
        // write 가 **영원히** 막힌다. 이 함수는 메인에서 불리므로 앱 전체가 멈춘다.
        // `SO_SNDTIMEO` 는 write 한 번마다의 제한이라(조금이라도 썼으면 그만큼 돌려주고 다음 write 가 다시 2초를 기다린다,
        // 실측 4초) 쓰기 전마다 남은 시간으로 다시 건다. 시간이 다 되면 EAGAIN 으로 돌아와 재시도 횟수에 들어간다.
        let deadline = Date().addingTimeInterval(sendTimeout)
        try data.withUnsafeBytes { p in
            var off = 0
            while off < data.count {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw Problem.write(EAGAIN) }
                var tv = timeoutValue(remaining: left)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let w = write(fd, p.baseAddress! + off, data.count - off)
                if w < 0 && errno == EINTR { continue }
                // EAGAIN/EWOULDBLOCK = 위 쓰기 제한에 걸렸다. 다른 쓰기 실패와 똑같이 던진다(재시도 대상).
                guard w > 0 else { throw Problem.write(errno) }
                off += w
            }
        }
    }
}

/// 받는 페인의 주소 — 페인 종류(CLI)마다 다르다.
/// `nonisolated` 인 이유 — 기본 격리(MainActor)면 `Equatable` 적합성도 메인액터에 묶여 `#expect` 에서 Swift 6 경고가 난다.
nonisolated enum PaneAddress: Equatable {
    /// Claude Code — 레지스트리(`~/.claude/sessions`)에서 인박스 소켓을 찾는 열쇠.
    case claude(session: String)
    /// Codex — 그 페인 전용 app-server 소켓과 스레드 id.
    case codex(socket: String, thread: String)

    /// `dispatch.delivered_session` 에 적는 값. `SessionStart` 훅의 `session_id` 와 같은 공간이다 —
    /// Codex 는 스레드 id 가 곧 `session_id` 라 `/new`(새 스레드 · source "startup")가 열린 배분을 실패로 닫는다.
    var sessionKey: String {
        switch self {
        case .claude(let session): session
        case .codex(_, let thread): thread
        }
    }
}

/// `Dispatcher` 가 쓰는 출구. 테스트는 가짜를 꽂는다. 던지면 그 배분 · 답의 재시도 횟수에 든다.
protocol PaneMessaging {
    func send(_ content: String, to address: PaneAddress) throws
}

/// 실제 출구 — Claude 는 인박스 소켓, Codex 는 `codex queue`(`CodexQueueSender`).
struct LivePaneMessaging: PaneMessaging {
    var inbox = LiveInbox()
    let codexToolchain: CodexToolchainResolver
    var runner: ArgvRunning = LiveArgvRunner()

    func send(_ content: String, to address: PaneAddress) throws {
        switch address {
        case .claude(let session):
            try inbox.send(content, toClaudeSession: session)
        case .codex(let socket, let thread):
            let toolchain = codexToolchain.current
            // 아직 못 구했으면(또는 지난 구하기가 실패했으면) 다시 구하기를 걸어 두고 던진다 — 재시도 틱 때는 간다.
            if toolchain == nil { codexToolchain.start() }
            try CodexQueueSender(codexPath: toolchain?.codexPath,
                                 environment: toolchain.map { CodexQueueSender.environment(loginPath: $0.path) } ?? [:],
                                 runner: runner)
                .send(content, socket: socket, thread: thread)
        }
    }
}

struct LiveInbox {
    var registry: URL = Inbox.defaultRegistry

    func send(_ content: String, toClaudeSession id: String) throws {
        guard let path = Inbox.socketPath(forClaudeSession: id, registry: registry) else { throw Inbox.Problem.noSocket }
        try Inbox.send(content, toSocket: path)
    }
}
