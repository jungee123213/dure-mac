import Darwin
import Foundation

/// 지난 실행이 남긴 두레 Codex 서버를 기동 때 끈다(이슈 #56).
///
/// 감시 셸(`CodexLaunch.serverWatchdog`)이 생긴 뒤로는 두레가 죽으면 서버도 따라 끝나지만, 그 전 빌드가 남긴 서버나
/// 감시 셸까지 함께 죽은 경우는 launchd(1) 밑에 남는다. 그런 서버만 고른다 —
/// 실행 파일 이름이 `codex` · 첫 인자가 `app-server` · `--listen unix://<두레 루트>/…` · **부모가 1**.
/// 떠 있는 두레(다른 빌드 포함)의 서버는 부모가 감시 셸이라 빠지고, 사용자 Codex 데몬(`--listen unix://` · `--managed-daemon`) ·
/// Codex Desktop · TUI(`--remote`) · 감시 셸 자신(실행 파일이 zsh)도 빠진다.
/// 끈 서버의 소켓 링크(와 대상 소켓) · 실패 표식을 지운다. home 과 로그는 남긴다(rollout 경로가 home 아래, 런타임과 같은 규칙).
nonisolated enum CodexOrphanReaper {

    struct Orphan: Equatable, Sendable {
        let pid: pid_t
        let socket: String
    }

    /// SIGTERM 뒤 이만큼 기다리고, 그때도 고아로 남은 것만 SIGKILL(런타임 `grace` 와 같음).
    static let grace: TimeInterval = LiveCodexProcessHandle.grace

    /// `ps -axww -o pid=,ppid=,command=` 출력에서 고아 두레 서버를 고른다. 순수 함수.
    static func orphans(psOutput: String, root: String) -> [Orphan] {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        let marker = " --listen unix://" + base + "/"
        return psOutput.split(separator: "\n").compactMap { raw in
            let fields = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]), ppid == 1 else { return nil }
            let command = String(fields[2])
            let words = command.split(separator: " ", maxSplits: 2)
            guard words.count >= 2, (words[0] as Substring).split(separator: "/").last == "codex",
                  words[1] == "app-server", let hit = command.range(of: marker) else { return nil }
            let rest = command[hit.upperBound...].prefix { $0 != " " }
            guard !rest.isEmpty else { return nil }
            return Orphan(pid: pid, socket: base + "/" + rest)
        }
    }

    /// 루트의 `*.sock` 중 링크 대상이 없는 것. 서버는 `/private/tmp/codex-daemon-<uid>/<hash>` 로의 링크로 소켓을 만들고
    /// 끝날 때 대상을 지운다 — 대상이 없으면 아무도 듣지 않는 링크다.
    static func danglingSockets(in root: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".sock") }.sorted().compactMap { name in
            let path = root.appendingPathComponent(name).path
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) != nil, !fm.fileExists(atPath: path) else { return nil }
            return path
        }
    }

    static func failMarker(forSocket socket: String) -> String {
        (socket as NSString).deletingPathExtension + ".fail"
    }

    // MARK: - 실제

    /// 앱 기동 때 한 번, 메인 밖에서. 블로킹(최대 `grace` 초).
    static func reapAtLaunch(root: URL = CodexLaunch.defaultRoot) {
        if let ps = psOutput() {
            let found = orphans(psOutput: ps, root: root.path)
            if !found.isEmpty {
                NSLog("[Dure] 지난 실행이 남긴 Codex 서버 \(found.count)개를 끕니다: \(found.map(\.pid))")
                for o in found { LiveCommandRunner.killTree(o.pid, SIGTERM) }
                Thread.sleep(forTimeInterval: grace)
                // 다시 읽어 아직 고아로 남은 같은 pid 만 — 그 사이 끝난 pid 를 다시 쓰는 남의 프로세스를 건드리지 않게.
                let still = Set(psOutput().map { orphans(psOutput: $0, root: root.path).map(\.pid) } ?? [])
                for o in found where still.contains(o.pid) { LiveCommandRunner.killTree(o.pid, SIGKILL) }
                for o in found {
                    CodexPaneRuntime.removeSocket(o.socket)
                    unlink(failMarker(forSocket: o.socket))
                }
            }
        }
        for path in danglingSockets(in: root) { unlink(path) }
    }

    private static func psOutput() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
