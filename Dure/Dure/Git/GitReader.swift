import Foundation

/// `git` 을 불러 레포 상태를 읽는다. F8.
///
/// **읽기 명령만 부른다** — `status` · `rev-parse` · `symbolic-ref` · `log` 뿐이다.
/// 커밋 · 브랜치 · 체크아웃은 사람이 직접 한다 (ADR-4).
/// **`nonisolated` 여야 한다.** 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// 라 아무 표시가 없으면 메인액터에 묶이고, 그러면 `Task.detached` 로 감싸도 실행 직전에
/// 메인으로 되돌아와 `git` 이 UI 를 막는다.
nonisolated enum GitReader {

    /// 실패하면 `nil`. **호출부는 마지막 값을 유지해야 한다** (D-13) —
    /// 읽지 못한 것을 `clean` 으로 표시하면 화면이 거짓말을 한다.
    static func read(at path: String) -> GitStatus? {
        // 커밋이 없는 레포에서는 `rev-parse --abbrev-ref HEAD` 가 실패한다(HEAD 가 아직
        // 가리킬 커밋이 없다). `symbolic-ref` 는 브랜치 이름만 읽으므로 그때도 답한다.
        // 둘 다 읽기 전용이다.
        guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], at: path)
                        ?? git(["symbolic-ref", "--short", "HEAD"], at: path),
              let porcelain = git(["status", "--porcelain"], at: path)
        else { return nil }
        // 커밋이 하나도 없는 레포에서 `git log` 는 실패한다. 그때도 브랜치와 dirty 는
        // 읽혔으므로 상태 전체를 버리지 않고 로그만 빈 값으로 둔다.
        // 최종 리뷰 F7 — 사용자 설정(`log.decorate`, `color.ui=always`)이 `(HEAD -> main)` 이나
        // ANSI 이스케이프를 섞으면 그대로 workspace.md 에 실린다. 명시적으로 끈다.
        let log = git(["log", "--oneline", "--no-decorate", "--no-color", "-5"], at: path) ?? ""
        return GitStatusParser.parse(branch: branch, porcelain: porcelain, log: log)
    }

    /// 종료코드가 0 이 아니면 nil. 레포가 아니거나 경로가 없으면 여기로 온다.
    private static func git(_ args: [String], at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()   // "not a git repository" 를 콘솔에 흘리지 않는다

        do {
            try process.run()
        } catch {
            // 경로 자체가 없으면 실행 전에 던진다.
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
