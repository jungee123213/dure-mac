// Dure/DureTests/CommandRunnerTests.swift
import Foundation
import Testing
@testable import Dure

/// 진짜 `zsh` 로 돈다(`echo` · `sleep` 만). Review Focus 4 — 멈추는 프로세스가 큐를 막지 않는다.
struct CommandRunnerTests {

    @Test func 출력과_종료_코드() async {
        let r = await LiveCommandRunner().run("echo hi; echo err >&2; exit 3", timeout: 30)
        #expect(String(decoding: r.stdout, as: UTF8.self).contains("hi"))
        #expect(String(decoding: r.stderr, as: UTF8.self).contains("err"))
        #expect(r.status == 3 && !r.timedOut)
    }

    @Test func 시간_초과() async {
        let start = Date()
        let r = await LiveCommandRunner(grace: 1).run("sleep 30", timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func SIGTERM_을_무시해도_상한_안에_돌아온다() async {
        let start = Date()
        let r = await LiveCommandRunner(grace: 1).run("trap '' TERM; sleep 30", timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func 파이프를_쥔_자식이_있어도_돌아온다() async {
        let start = Date()
        let r = await LiveCommandRunner(grace: 1).run("sleep 30 & echo started", timeout: 20)
        #expect(!r.timedOut)
        #expect(String(decoding: r.stdout, as: UTF8.self).contains("started"))
        #expect(Date().timeIntervalSince(start) < 8)
    }

    /// 루트는 TERM 에 죽지만 자식은 TERM 을 무시한다 — 돌아온 뒤 그 자식이 남아 있으면 안 된다.
    @Test func 루트가_먼저_죽어도_TERM_을_무시하는_자손을_정리한다() async throws {
        let tag = "dure-t7-\(UUID().uuidString.prefix(8))"
        let script = "(trap '' TERM; exec -a \(tag) sleep 31) & sleep 30"
        _ = await LiveCommandRunner(grace: 1).run(script, timeout: 3)
        // SIGKILL 된 프로세스가 사라지는 데 부하에 따라 시간이 걸린다 — 최대 5초까지 지켜본다.
        var left = ""
        for _ in 0..<50 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-fl", tag]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run()
            left = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "남은 pid: \(left)")
    }

    /// 최종 리뷰 F5e — 앱 종료 때 돌고 있는 실행을 죽인다. 다른 러너 인스턴스(병렬 테스트)는 건드리지 않는다.
    @Test func cancelAll_은_돌고_있는_실행을_죽인다() async throws {
        let runner = LiveCommandRunner(grace: 1)
        let started = Date()
        async let r = runner.run("sleep 30", timeout: 60)
        for _ in 0..<100 where runner.tracker.running.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!runner.tracker.running.isEmpty)
        runner.cancelAll()
        let result = await r
        #expect(result.cancelled && !result.timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(runner.tracker.running.isEmpty)
        // 죽인 뒤의 새 실행은 취소로 표시되지 않는다
        #expect(await runner.run("echo ok", timeout: 10).cancelled == false)
    }

    /// #58 — 두레가 정리 없이 끝나면 생명줄의 쓰는 끝이 닫힌다. 그때 도는 명령(평가 중인 `claude -p`)이 트리째 끝나야 한다.
    @Test func 생명줄이_끊기면_도는_명령_트리가_끝난다() async throws {
        let tag = "dure-t58-\(UUID().uuidString.prefix(8))"
        let start = Date()
        let r = await Task.detached {
            LiveCommandRunner.runBlocking("(exec -a \(tag) sleep 31) & exec sleep 30", timeout: 20, grace: 1,
                                          innerFlags: "-c", onStart: { end in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { end.close() }
            })
        }.value
        #expect(!r.timedOut)
        #expect(r.status != 0)
        #expect(Date().timeIntervalSince(start) < 8)
        var left = ""
        for _ in 0..<50 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-fl", tag]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run()
            left = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "남은 pid: \(left)")
    }

    /// 감시 셸을 거쳐도 짧은 명령은 지금처럼 바로 돌아오고, 출력 · 종료 코드가 그대로다.
    @Test func 감시_셸을_거쳐도_짧은_명령은_바로_돌아온다() {
        let start = Date()
        let r = LiveCommandRunner.runBlocking("echo done; exit 5", timeout: 10, grace: 1, innerFlags: "-c")
        #expect(String(decoding: r.stdout, as: UTF8.self) == "done\n")
        #expect(r.status == 5 && !r.timedOut)
        #expect(Date().timeIntervalSince(start) < 0.9)
    }

    @Test func 표지_뒤만_읽는다() {
        let out = "[oh-my-zsh] Would you like to update?\n__DURE_OUT__\n[\n  {\"number\": 1}\n]\n"
        #expect(CommandOutput.afterMarker(Data(out.utf8)) == "[\n  {\"number\": 1}\n]\n")
        #expect(CommandOutput.afterMarker(Data("표지 없음".utf8)) == nil)
    }
}
