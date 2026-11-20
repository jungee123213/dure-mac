import Foundation
import Testing
@testable import Dure

/// 이슈 #16 — 조율자를 띄울 때 무엇을 넘기는가. 스토어는 실제 DB·홈을 쓰므로 판단만 여기서 본다.
struct LaunchPlanTests {

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dure-lp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 폴더 없는 레포를 `--add-dir`·허용 규칙에 넣으면 claude 가 기동에서 실패하거나 없는 경로를 허용한다.
    @Test func 폴더가_없는_레포는_뺀다() throws {
        let d = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let ok = Repo(id: "a", workspaceId: "w", path: d.path)
        let gone = Repo(id: "b", workspaceId: "w", path: "/nonexistent-\(UUID().uuidString)")
        #expect(LaunchPlan.repoPaths([ok, gone]) == [d.path])
    }

    @Test func 레포_CLAUDE_md_가_있으면_경로를_준다() throws {
        let d = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let repo = Repo(id: "a", workspaceId: "w", path: d.path)
        #expect(LaunchPlan.instructionsPath(for: repo) == nil)
        try Data("# r".utf8).write(to: d.appendingPathComponent("CLAUDE.md"))
        #expect(LaunchPlan.instructionsPath(for: repo) == d.appendingPathComponent("CLAUDE.md").path)
    }

    @Test func Codex_페인의_레포_지시문은_AGENTS_md_가_먼저다() throws {
        let d = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let repo = Repo(id: "a", workspaceId: "w", path: d.path)
        #expect(LaunchPlan.instructionsPath(for: repo, kind: .codex) == nil)
        try Data("# c".utf8).write(to: d.appendingPathComponent("CLAUDE.md"))
        #expect(LaunchPlan.instructionsPath(for: repo, kind: .codex) == d.appendingPathComponent("CLAUDE.md").path)
        try Data("# a".utf8).write(to: d.appendingPathComponent("AGENTS.md"))
        #expect(LaunchPlan.instructionsPath(for: repo, kind: .codex) == d.appendingPathComponent("AGENTS.md").path)
        #expect(LaunchPlan.instructionsPath(for: repo, kind: .claude) == d.appendingPathComponent("CLAUDE.md").path)
    }
}
