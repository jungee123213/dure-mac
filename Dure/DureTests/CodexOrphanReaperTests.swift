import Testing
import Foundation
@testable import Dure

/// 이슈 #56 — 기동 때 지난 실행이 남긴 두레 Codex 서버만 고른다.
struct CodexOrphanReaperTests {

    private let root = "/Users/u/.dure/codex"
    private let bin = "/Users/u/.nvm/versions/node/v24/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin"

    @Test func 부모가_launchd_인_두레_소켓_서버만_고른다() {
        let ps = """
          25960     1 \(bin)/codex app-server --listen unix:///Users/u/.dure/codex/cf92adbd.sock -c check_for_update_on_startup=false -c features.apps=false
          56489     1 \(bin)/codex app-server --listen unix:///Users/u/.dure/codex/927c0a9e.sock -c x=1
          70001  4242 \(bin)/codex app-server --listen unix:///Users/u/.dure/codex/aaaa1111.sock -c x=1
          29252     1 /Users/u/.codex/packages/app-server-daemon/releases/0.171.0/bin/codex app-server --listen unix:// --analytics-default-enabled --managed-daemon
           2943     1 /Users/u/.codex/packages/app-server-daemon/releases/0.171.0/bin/codex app-server daemon pid-update-loop
          70002     1 \(bin)/codex app-server --listen unix:///tmp/other/x.sock
          70003     1 \(bin)/codex app-server --listen unix:///Users/u/.dure/codexfoo/x.sock
          70004     1 \(bin)/codex --remote unix:///Users/u/.dure/codex/cf92adbd.sock -C /r
          70005     1 /bin/zsh -c exec 3<&0 </dev/null zsh -ilc export DURE_SESSION=x; exec codex app-server --listen unix:///Users/u/.dure/codex/bbbb2222.sock
          91329 25960 \(bin)/codex-code-mode-host
        garbage line
        """
        #expect(CodexOrphanReaper.orphans(psOutput: ps, root: root) == [
            .init(pid: 25960, socket: "/Users/u/.dure/codex/cf92adbd.sock"),
            .init(pid: 56489, socket: "/Users/u/.dure/codex/927c0a9e.sock"),
        ])
    }

    @Test func 루트_끝_빗금은_무시한다() {
        let ps = "  1234 1 \(bin)/codex app-server --listen unix:///Users/u/.dure/codex/ab.sock"
        #expect(CodexOrphanReaper.orphans(psOutput: ps, root: root + "/").map(\.pid) == [1234])
    }

    @Test func 대상이_없는_소켓_링크만_고른다() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let existing = dir.appendingPathComponent("target")
        try Data().write(to: existing)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("a.sock").path, withDestinationPath: "/nonexistent/x")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("b.sock").path, withDestinationPath: existing.path)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("c.log").path, withDestinationPath: "/nonexistent/y")
        #expect(CodexOrphanReaper.danglingSockets(in: dir) == [dir.appendingPathComponent("a.sock").path])
    }

    @Test func 실패_표식_경로는_소켓과_같은_이름이다() {
        #expect(CodexOrphanReaper.failMarker(forSocket: "/Users/u/.dure/codex/cf92adbd.sock")
                == "/Users/u/.dure/codex/cf92adbd.fail")
    }
}
