import Foundation

/// `git` 을 불러 레포 상태를 읽는다. F8.
///
/// **읽기 명령만 부른다** — `status` 와 `rev-parse` 둘뿐이다.
/// 커밋 · 브랜치 · 체크아웃은 사람이 직접 한다 (ADR-4).
/// **`nonisolated` 여야 한다.** 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// 라 아무 표시가 없으면 메인액터에 묶이고, 그러면 `Task.detached` 로 감싸도 실행 직전에
/// 메인으로 되돌아와 `git` 이 UI 를 막는다.
nonisolated enum GitReader {

    /// 실패하면 `nil`. **호출부는 마지막 값을 유지해야 한다** (D-13) —
    /// 읽지 못한 것을 `clean` 으로 표시하면 화면이 거짓말을 한다.
    static func read(at path: String) -> GitStatus? {
        guard let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], at: path),
              let porcelain = git(["status", "--porcelain"], at: path)
        else { return nil }
        return GitStatusParser.parse(branch: branch, porcelain: porcelain)
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
