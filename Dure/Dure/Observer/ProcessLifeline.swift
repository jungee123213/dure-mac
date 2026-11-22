// Dure/Dure/Observer/ProcessLifeline.swift
import Darwin
import Foundation

/// 두레가 띄우는 셸 자식(Codex 전용 서버 · `claude -p` · `gh` · `git` …)이 **두레가 어떻게 끝나든 따라 끝나게** 하는 감시 셸(#56 · #58).
///
/// 앱 종료 알림(`willTerminate`)은 Xcode 재실행 · 강제 종료 · 크래시 때 오지 않는다 — 그 알림에서만 끄면 자식이
/// launchd 밑에 남는다(#56 실물: Codex 서버 8개. `claude -p` 는 남아서 한도를 쓰고, 다음 기동이 같은 평가를 또 돌린다).
/// 그래서 두레가 stdin 으로 파이프를 주고 **쓰는 끝은 두레만 쥔다**(`FD_CLOEXEC` — PTY 자식 등에 새지 않게).
/// 두레가 어떻게 끝나든 커널이 그 끝을 닫는다.
///
/// 바깥 셸(`/bin/zsh -c` — `.zshrc` 를 읽지 않는다, `$1` 안쪽 플래그 · `$2` 스크립트)은 그 파이프를 fd 3 으로 옮기고 안쪽 셸의
/// stdin 은 `/dev/null` 로 둔다(`.zshrc` 가 입력을 기다려도 멈추지 않게 — 예전과 같은 stdin). 감시 블록은 fd 3 의 EOF 를
/// 기다렸다가 안쪽 트리를 SIGTERM, 3초 뒤 남으면 SIGKILL. 안쪽이 먼저 끝나면 감시 블록을 끄고 그 종료 코드로 끝난다.
/// 감시 블록은 출력을 `/dev/null` 로 둔다 — 명령의 stdout · stderr 파이프를 쥐면 명령이 끝나도 EOF 가 늦는다.
nonisolated enum ProcessLifeline {

    static let watchdog = #"""
    exec 3<&0 </dev/null
    /bin/zsh "$1" "$2" 3<&- &
    srv=$!
    { read -r -u 3 _; dure_tree() { local c; for c in $(/usr/bin/pgrep -P $1); do dure_tree $c; done; print -r -- $1; }; p=($(dure_tree $srv)); kill -TERM $p 2>/dev/null; sleep 3; kill -0 $srv 2>/dev/null && kill -KILL $p 2>/dev/null; } >/dev/null 2>&1 &
    w=$!
    wait $srv
    st=$?
    kill $w 2>/dev/null
    exit $st
    """#

    /// `/bin/zsh` 에 줄 인자. 테스트는 `.zshrc` 를 안 읽게 `innerFlags: "-c"` 를 준다.
    static func arguments(script: String, innerFlags: String = "-ilc") -> [String] {
        ["-c", watchdog, "zsh", innerFlags, script]
    }

    /// stdin 으로 줄 파이프와 그 쓰는 끝. `Process.standardInput = pipe` 로 주고 쓰는 끝은 두레가 쥔다.
    static func make() -> (pipe: Pipe, writeEnd: WriteEnd) {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        return (pipe, WriteEnd(pipe.fileHandleForWriting))
    }

    /// 생명줄의 쓰는 끝. 닫으면 감시 셸이 안쪽 트리를 끈다. 여러 곳(종료 핸들러 · 멈춤)이 닫으므로 한 번만 닫는다.
    final class WriteEnd: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var open = true

        init(_ handle: FileHandle) { self.handle = handle }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return }
            open = false
            try? handle.close()
        }
    }
}
