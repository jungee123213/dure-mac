import Testing
import Foundation
@testable import Dure

/// 이슈 #56 · #58 — 두레가 어떻게 끝나든 자식이 따라 끝나게 하는 감시 셸. 실제 `/bin/zsh` 로 돌린다(`.zshrc` 를 안 읽게 안쪽은 `-c`).
struct ProcessLifelineTests {

    @Test func 감시_셸은_파이프를_fd3_으로_옮기고_안쪽_셸은_stdin_을_비운다() {
        let args = ProcessLifeline.arguments(script: "exec codex app-server")
        #expect(args == ["-c", ProcessLifeline.watchdog, "zsh", "-ilc", "exec codex app-server"])
        let w = ProcessLifeline.watchdog
        #expect(w.hasPrefix("exec 3<&0 </dev/null"))
        #expect(w.contains("read -r -u 3"))
        #expect(w.contains("kill -TERM"))
        #expect(w.contains("kill -KILL"))
        #expect(w.contains("wait $srv"))
        // 감시 블록이 명령의 출력 파이프를 쥐지 않는다(#58).
        #expect(w.contains("} >/dev/null 2>&1 &"))
    }

    private struct Run {
        let process: Process
        let lifeline: FileHandle
    }

    private func start(_ script: String) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ProcessLifeline.arguments(script: script, innerFlags: "-c")
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return Run(process: p, lifeline: pipe.fileHandleForWriting)
    }

    private func waitExit(_ p: Process, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
    }

    private func children(of pid: pid_t, within seconds: TimeInterval = 3) -> [pid_t] {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            let found = LiveCommandRunner.descendants(of: pid)
            if !found.isEmpty { return found }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return []
    }

    @Test func 파이프가_닫히면_서버_트리를_끈다() throws {
        // 서버 흉내: 자식 하나를 두고 오래 산다(code-mode-host 처럼).
        let r = try start("sleep 30 & exec sleep 31")
        let tree = children(of: r.process.processIdentifier)
        #expect(!tree.isEmpty)
        try r.lifeline.close()
        #expect(waitExit(r.process, within: 6))
        Thread.sleep(forTimeInterval: 0.2)
        for pid in tree { #expect(kill(pid, 0) != 0, "남은 pid \(pid)") }
    }

    @Test func 서버가_먼저_끝나면_그_종료_코드로_끝난다() throws {
        let r = try start("exit 7")
        #expect(waitExit(r.process, within: 5))
        #expect(r.process.terminationStatus == 7)
        try? r.lifeline.close()
    }

    @Test func 안쪽_셸의_stdin_은_파이프가_아니다() throws {
        // stdin 이 파이프면 read 는 5초를 다 기다린다(쓰는 끝이 열려 있으므로). /dev/null 이면 바로 EOF.
        let started = Date()
        let r = try start("read -t 5 x; exit 3")
        #expect(waitExit(r.process, within: 6))
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(r.process.terminationStatus == 3)
        try? r.lifeline.close()
    }
}

struct ProcessLifelineWriteEndTests {
    @Test func 생명줄은_두_번_닫아도_한_번만_닫는다() throws {
        let (pipe, line) = ProcessLifeline.make()
        line.close()
        line.close()
        // 쓰는 끝이 닫혔으면 읽는 쪽은 바로 EOF.
        #expect(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
