import Foundation
import Testing
@testable import Dure

/// 단계 4 — 앱 → 페인. 실측(2026-10-08): `{"type":"user","message":{"role":"user","content":"…"}}` 한 줄이면
/// 매뉴얼 모드 세션이 새 턴을 시작한다. 소켓 경로는 `~/.claude/sessions/<pid>.json` 의 `messagingSocketPath`.
struct InboxTests {

    static func registry(_ files: [String: String]) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dure-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return d
    }

    @Test func 세션_id_로_소켓을_찾는다() throws {
        let reg = try Self.registry([
            "111.json": #"{"pid":111,"sessionId":"aaa","messagingSocketPath":"/tmp/cc-socks/111.sock","name":"x"}"#,
            "222.json": #"{"pid":222,"sessionId":"bbb","messagingSocketPath":"/tmp/cc-socks/222.sock"}"#,
            "222.abc.key": #"{"peerToken":"t"}"#,
            "junk.json": "{not json",
        ])
        defer { try? FileManager.default.removeItem(at: reg) }
        #expect(Inbox.socketPath(forClaudeSession: "bbb", registry: reg) == "/tmp/cc-socks/222.sock")
        #expect(Inbox.socketPath(forClaudeSession: "zzz", registry: reg) == nil)
    }

    @Test func 레지스트리가_없으면_nil() {
        #expect(Inbox.socketPath(forClaudeSession: "a", registry: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) == nil)
    }

    /// Review Focus 2 — 따옴표 · 줄바꿈 · 한글 · 중괄호가 있어도 **유효한 JSON 한 줄**.
    @Test func 프레임은_JSON_한_줄이다() throws {
        let content = "## 배분 \"7\"\n{a: b}\n한글 `x`"
        let f = Inbox.frame(content)
        #expect(f.hasSuffix("\n") && f.dropLast().contains("\n") == false)
        let o = try #require(try JSONSerialization.jsonObject(with: Data(f.utf8)) as? [String: Any])
        #expect(o["type"] as? String == "user")
        let m = try #require(o["message"] as? [String: Any])
        #expect(m["role"] as? String == "user" && m["content"] as? String == content)
    }

    /// 진짜 소켓으로 한 바퀴 — 받는 쪽은 테스트가 띄운 MCPServer(줄 단위 서버면 뭐든 된다).
    @Test func 소켓에_한_줄을_쓴다() throws {
        let dir = try MCPServerTests.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("in.sock").path
        let got = LockedBox<[String]>([])
        let server = MCPServer(path: path) { line, reply in got.mutate { $0.append(line) }; reply(nil) }
        try server.start()
        defer { server.stop() }
        try Inbox.send("안녕\n둘째 줄", toSocket: path)
        Thread.sleep(forTimeInterval: 0.3)
        let lines = got.value
        #expect(lines.count == 1)
        #expect(lines.first?.contains("\"content\":\"안녕\\n둘째 줄\"") == true)
    }

    /// I-5 — 받는 쪽이 붙어는 있는데 읽지 않으면(멈춘 claude) 버퍼가 찬 write 가 영원히 막혀 메인(앱 전체)이 선다.
    /// 리스너만 있고 accept 도 read 도 안 하는 소켓에 1MB 를 보내면 쓰기 제한(2초)으로 `Problem.write` 가 와야 한다.
    @Test func 읽지_않는_소켓에는_제한_시간_안에_실패한다() throws {
        let dir = try MCPServerTests.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("stall.sock").path
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(lfd >= 0)
        defer { close(lfd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: cap) { strncpy($0, src, cap - 1) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(lfd, 1) == 0)

        let start = Date()
        var problem: Inbox.Problem?
        do { try Inbox.send(String(repeating: "x", count: 1 << 20), toSocket: path) } catch let p as Inbox.Problem { problem = p }
        let elapsed = Date().timeIntervalSince(start)
        guard case .write = problem else { Issue.record("Problem.write 가 아니다: \(String(describing: problem))"); return }
        #expect(elapsed < 3)
    }

    /// Darwin 의 `SO_SNDTIMEO` {0,0} 은 무제한이다 — 1µs 미만이 남아도 0 이 아닌 값이어야 한다.
    @Test func 쓰기_제한_값은_0_이_되지_않는다() {
        let tiny = Inbox.timeoutValue(remaining: 1e-9)
        #expect(tiny.tv_sec == 0 && tiny.tv_usec == 1)
        let normal = Inbox.timeoutValue(remaining: 1.5)
        #expect(normal.tv_sec == 1 && normal.tv_usec == 500_000)
    }

    @Test func 소켓이_없으면_던진다() {
        #expect(throws: Inbox.Problem.self) { try Inbox.send("x", toSocket: "/tmp/dure-none-\(UUID().uuidString).sock") }
    }

    @Test func LiveInbox_는_레지스트리에서_찾아_보낸다() throws {
        let dir = try MCPServerTests.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("live.sock").path
        let got = LockedBox<[String]>([])
        let server = MCPServer(path: path) { line, reply in got.mutate { $0.append(line) }; reply(nil) }
        try server.start()
        defer { server.stop() }
        let reg = try Self.registry(["5.json": #"{"sessionId":"s5","messagingSocketPath":"\#(path)"}"#])
        defer { try? FileManager.default.removeItem(at: reg) }
        try LiveInbox(registry: reg).send("hi", toClaudeSession: "s5")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(got.value.count == 1)
        #expect(throws: Inbox.Problem.self) { try LiveInbox(registry: reg).send("hi", toClaudeSession: "nope") }
    }

    // MARK: - 받는 페인 종류로 출구 고르기 (2단계 Task 3)

    /// 이 테스트는 셸을 띄우지 않는다 — 리졸버의 `resolve` 를 가짜로 꽂는다.
    static func resolver(_ toolchain: CodexToolchain?, calls: LockedBox<Int> = LockedBox(0),
                         queue: DispatchQueue = DispatchQueue(label: "test.resolver")) -> CodexToolchainResolver {
        CodexToolchainResolver(queue: queue) { calls.mutate { $0 += 1 }; return toolchain }
    }

    @Test @MainActor func Claude_주소는_인박스_소켓으로_간다() throws {
        let dir = try MCPServerTests.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("live.sock").path
        let got = LockedBox<[String]>([])
        let server = MCPServer(path: path) { line, reply in got.mutate { $0.append(line) }; reply(nil) }
        try server.start()
        defer { server.stop() }
        let reg = try Self.registry(["5.json": #"{"sessionId":"s5","messagingSocketPath":"\#(path)"}"#])
        defer { try? FileManager.default.removeItem(at: reg) }
        let runner = CodexQueueSenderTests.FakeArgvRunner()
        let out = LivePaneMessaging(inbox: LiveInbox(registry: reg), codexToolchain: Self.resolver(nil), runner: runner)
        try out.send("hi", to: .claude(session: "s5"))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(got.value.count == 1 && got.value.first?.contains(#""content":"hi""#) == true)
        #expect(runner.calls.isEmpty)
        #expect(throws: Inbox.Problem.self) { try out.send("hi", to: .claude(session: "nope")) }
    }

    @Test @MainActor func Codex_주소는_codex_queue_로_간다() throws {
        let runner = CodexQueueSenderTests.FakeArgvRunner()
        let resolver = Self.resolver(CodexToolchain(codexPath: "/nvm/bin/codex", path: "/nvm/bin:/usr/bin"))
        resolver.start(); resolver.queue.sync {}
        let out = LivePaneMessaging(codexToolchain: resolver, runner: runner)
        try out.send("일", to: .codex(socket: "/s.sock", thread: "T1"))
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/nvm/bin/codex")
        #expect(call.arguments == ["queue", "--remote", "unix:///s.sock", "--thread", "T1", "--message", "일"])
        #expect(call.environment["PATH"] == "/nvm/bin:/usr/bin" && call.environment["DURE_SESSION"] == nil)
    }

    /// 아직 못 구했으면 던진다(재시도 횟수에 든다) — 그리고 구하기를 다시 시작해 다음 재시도 때는 간다.
    @Test @MainActor func codex_경로를_아직_모르면_던지고_구하기를_시작한다() throws {
        let runner = CodexQueueSenderTests.FakeArgvRunner()
        let calls = LockedBox(0)
        let resolver = Self.resolver(CodexToolchain(codexPath: "/c", path: "/p"), calls: calls)
        let out = LivePaneMessaging(codexToolchain: resolver, runner: runner)
        #expect(throws: CodexQueueSender.Problem.codexNotResolved) {
            try out.send("일", to: .codex(socket: "/s.sock", thread: "T1"))
        }
        resolver.queue.sync {}
        #expect(calls.value == 1 && runner.calls.isEmpty)
        try out.send("일", to: .codex(socket: "/s.sock", thread: "T1"))
        #expect(runner.calls.count == 1)
    }

    /// 멈춘 큐 깨우기(2단계 Task 4) — Codex 전달이 **성공했을 때만** 스토어에 알린다(그 페인 런타임이 5초를 잰다).
    @Test @MainActor func Codex_전달이_성공하면_전달_알림을_부른다() throws {
        let resolver = Self.resolver(CodexToolchain(codexPath: "/c", path: "/p"))
        resolver.start(); resolver.queue.sync {}
        let seen = LockedBox<[String]>([])
        var out = LivePaneMessaging(codexToolchain: resolver, runner: CodexQueueSenderTests.FakeArgvRunner())
        out.onCodexDelivered = { socket, thread in seen.mutate { $0.append("\(socket) \(thread)") } }
        try out.send("일", to: .codex(socket: "/s.sock", thread: "T1"))
        #expect(seen.value == ["/s.sock T1"])

        var failing = LivePaneMessaging(codexToolchain: resolver,
                                        runner: CodexQueueSenderTests.FakeArgvRunner(.init(status: 1, stderr: "x", timedOut: false)))
        failing.onCodexDelivered = { socket, thread in seen.mutate { $0.append("\(socket) \(thread)") } }
        #expect(throws: CodexQueueSender.Problem.self) { try failing.send("일", to: .codex(socket: "/s.sock", thread: "T2")) }
        #expect(seen.value == ["/s.sock T1"])
    }

    @Test func 주소의_세션_열쇠는_Claude_세션이나_Codex_스레드다() {
        #expect(PaneAddress.claude(session: "cc-a").sessionKey == "cc-a")
        #expect(PaneAddress.codex(socket: "/s", thread: "T1").sessionKey == "T1")
    }
}

/// 테스트 전용 — 소켓 큐와 테스트 스레드가 같이 만지는 값.
final class LockedBox<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
