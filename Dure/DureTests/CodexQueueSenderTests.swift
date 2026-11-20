import Foundation
import Testing
@testable import Dure

/// 2단계 Task 3 — Codex 페인 전달(`codex queue --remote`). 진짜 codex · 셸은 돌리지 않는다 — 러너는 가짜,
/// 실제 러너 테스트는 `/bin/sleep` · `/bin/ls` 같은 셸 아닌 실행 파일만 쓴다.
struct CodexQueueSenderTests {

    final class FakeArgvRunner: ArgvRunning, @unchecked Sendable {
        struct Call { var executable: String; var arguments: [String]; var environment: [String: String]; var timeout: TimeInterval }
        private let lock = NSLock()
        private var log: [Call] = []
        let result: ArgvResult
        init(_ result: ArgvResult = .init(status: 0, stderr: "", timedOut: false)) { self.result = result }
        func run(executable: String, arguments: [String], environment: [String: String],
                 timeout: TimeInterval) -> ArgvResult {
            lock.withLock { log.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout)) }
            return result
        }
        var calls: [Call] { lock.withLock { log } }
    }

    @Test func queue_인자는_셸_없이_argv_로_간다() throws {
        let runner = FakeArgvRunner()
        let text = "it's $HOME `x` \"q\"\n둘째 줄 $(rm -rf /)"
        try CodexQueueSender(codexPath: "/opt/bin/codex", environment: ["PATH": "/opt/bin:/usr/bin"], runner: runner)
            .send(text, socket: "/Users/u/.dure/codex/abcd1234.sock", thread: "T1")
        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable == "/opt/bin/codex")
        #expect(call.arguments == ["queue", "--remote", "unix:///Users/u/.dure/codex/abcd1234.sock",
                                   "--thread", "T1", "--message", text])
        #expect(call.environment["PATH"] == "/opt/bin:/usr/bin")
        #expect(call.timeout == 3)
    }

    @Test func 종료_코드가_0_이_아니면_던진다() {
        let runner = FakeArgvRunner(.init(status: 1, stderr: "Error: failed to connect to remote app server\n", timedOut: false))
        let sender = CodexQueueSender(codexPath: "/opt/bin/codex", environment: [:], runner: runner)
        #expect(throws: CodexQueueSender.Problem.exit(1, "Error: failed to connect to remote app server")) {
            try sender.send("x", socket: "/s", thread: "T1")
        }
    }

    @Test func 시간이_넘으면_던진다() {
        let runner = FakeArgvRunner(.init(status: -9, stderr: "", timedOut: true))
        let sender = CodexQueueSender(codexPath: "/opt/bin/codex", environment: [:], timeout: 0.5, runner: runner)
        #expect(throws: CodexQueueSender.Problem.timedOut) { try sender.send("x", socket: "/s", thread: "T1") }
        #expect(runner.calls.first?.timeout == 0.5)
    }

    @Test func codex_경로를_아직_모르면_실행하지_않고_던진다() {
        let runner = FakeArgvRunner()
        let sender = CodexQueueSender(codexPath: nil, environment: [:], runner: runner)
        #expect(throws: CodexQueueSender.Problem.codexNotResolved) { try sender.send("x", socket: "/s", thread: "T1") }
        #expect(runner.calls.isEmpty)
    }

    @Test func 하위_프로세스_환경은_로그인_PATH_로_바꾸고_두레_표식을_뺀다() {
        let env = CodexQueueSender.environment(loginPath: "/nvm/bin:/usr/bin",
                                               base: ["PATH": "/usr/bin", "HOME": "/Users/u", "DURE_SESSION": "s",
                                                      "DURE_AGENT_KIND": "codex"])
        #expect(env == ["PATH": "/nvm/bin:/usr/bin", "HOME": "/Users/u"])
    }

    // MARK: - 실제 러너 (셸 아닌 실행 파일)

    @Test func 실제_러너는_시간이_넘으면_죽이고_시간_초과로_돌려준다() {
        let started = Date()
        let r = LiveArgvRunner().run(executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 0.3)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func 실제_러너는_종료_코드와_stderr_를_돌려준다() {
        let r = LiveArgvRunner().run(executable: "/bin/ls", arguments: ["/dure-none-\(UUID().uuidString)"],
                                     environment: [:], timeout: 3)
        #expect(!r.timedOut && r.status != 0 && !r.stderr.isEmpty)
        let ok = LiveArgvRunner().run(executable: "/bin/ls", arguments: ["/"], environment: [:], timeout: 3)
        #expect(!ok.timedOut && ok.status == 0)
    }

    /// `pid` 가 사라질 때까지(최대 2초) 기다린다. 부모가 먼저 죽으면 launchd 가 거두기까지 잠깐 좀비로 남는다.
    static func gone(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// 리뷰 Important — 시간 초과 때 자손까지 죽인다. `sh` 가 자기 pid 와 자식 `sleep` 의 pid 를 stderr 로 알려 준다.
    @Test func 실제_러너는_시간이_넘으면_자식까지_트리째_죽인다() throws {
        let r = LiveArgvRunner().run(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $$ $! >&2; wait"],
                                     environment: [:], timeout: 0.5)
        #expect(r.timedOut)
        let pids = r.stderr.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        try #require(pids.count == 2)
        #expect(Self.gone(pids[0]))   // sh
        #expect(Self.gone(pids[1]))   // sleep (손자 쪽)
    }

    /// 리뷰 Important — 메인에서 불릴 때 시간 초과 경로가 런루프를 돌리면(`waitUntilExit`) 메인 큐에 쌓인 일
    /// (MCP 요청 · 재시도 틱)이 전달 한가운데 끼어들어 같은 배분을 두 번 보낸다. 미리 넣어 둔 메인 큐 블록이 돌면 안 된다.
    /// 탐침 둘 — 메인 큐 블록과 메인 런루프 타이머. 런루프를 한 번이라도 돌리면 타이머가 (중첩 실행 안에서) 불린다.
    @Test @MainActor func 시간_초과_경로는_메인_런루프를_돌리지_않는다() {
        final class Flag: @unchecked Sendable { var sending = true; var ran: [String] = [] }
        let f = Flag()
        DispatchQueue.main.async { if f.sending { f.ran.append("main-queue") } }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in if f.sending { f.ran.append("timer") } }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        let r = LiveArgvRunner().run(executable: "/bin/sh", arguments: ["-c", "sleep 30 & wait"],
                                     environment: [:], timeout: 0.3)
        f.sending = false
        #expect(r.timedOut)
        #expect(f.ran.isEmpty)
    }

    @Test func 자손_목록은_하위_프로세스_없이_구한다() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30 & wait"]
        try p.run()
        defer { p.terminate() }
        var kids: [pid_t] = []
        let deadline = Date().addingTimeInterval(2)
        while kids.isEmpty, Date() < deadline {
            kids = LiveArgvRunner.descendants(of: p.processIdentifier)
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(kids.count == 1)
        for k in kids { kill(k, SIGKILL) }
    }

    @Test func 실제_러너는_실행_파일이_없으면_실패로_돌려준다() {
        let r = LiveArgvRunner().run(executable: "/dure-none-\(UUID().uuidString)", arguments: [], environment: [:], timeout: 1)
        #expect(!r.timedOut && r.status != 0)
    }

    // MARK: - codex 경로 · PATH 캐시

    @Test func 로그인_셸_출력에서_codex_경로와_PATH_를_읽는다() {
        let out = Data("zshrc 잡음\n\(CommandOutput.marker)\n/nvm/bin/codex\n/nvm/bin:/usr/bin\n".utf8)
        #expect(CodexToolchain.parse(out) == CodexToolchain(codexPath: "/nvm/bin/codex", path: "/nvm/bin:/usr/bin"))
    }

    @Test func codex_가_없거나_절대_경로가_아니면_못_읽는다() {
        #expect(CodexToolchain.parse(Data("\(CommandOutput.marker)\n\n/usr/bin\n".utf8)) == nil)
        #expect(CodexToolchain.parse(Data("\(CommandOutput.marker)\ncodex: aliased to x\n/usr/bin\n".utf8)) == nil)
        #expect(CodexToolchain.parse(Data("표지 없음\n/nvm/bin/codex\n/usr/bin\n".utf8)) == nil)
        #expect(CodexToolchain.parse(Data("\(CommandOutput.marker)\n/nvm/bin/codex\n\n".utf8)) == nil)
    }

    @Test func 캐시는_한_번만_구하고_실패하면_다음_start_에_다시_구한다() {
        let queue = DispatchQueue(label: "test.resolver")
        let calls = LockedBox(0)
        let answers = LockedBox<[CodexToolchain?]>([nil, CodexToolchain(codexPath: "/c", path: "/p")])
        let resolver = CodexToolchainResolver(queue: queue) {
            calls.mutate { $0 += 1 }
            var next: CodexToolchain?
            answers.mutate { next = $0.removeFirst() }
            return next
        }
        #expect(resolver.current == nil)
        resolver.start(); queue.sync {}
        #expect(resolver.current == nil && calls.value == 1)
        resolver.start(); queue.sync {}
        #expect(resolver.current == CodexToolchain(codexPath: "/c", path: "/p") && calls.value == 2)
        resolver.start(); queue.sync {}
        #expect(calls.value == 2)   // 구한 뒤로는 다시 셸을 띄우지 않는다
    }
}
