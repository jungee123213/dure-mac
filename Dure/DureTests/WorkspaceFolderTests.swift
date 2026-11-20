import Foundation
import Testing
@testable import Dure

/// 조율자 설계 단계 1 · 워크스페이스 폴더.
/// **`root` 를 인자로 받는 이유는 테스트가 실제 `~/.dure` 를 건드리지 않기 위해서다.**
/// static var 로 두면 Swift Testing 이 테스트를 병렬로 돌릴 때 서로 덮어쓴다.
struct WorkspaceFolderTests {

    static func tempRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dure-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func 폴더_이름은_워크스페이스_아이디다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 이름이 아니라 id 를 쓴다 — 이름에는 공백·슬래시·한글이 들어가고 나중에 바뀐다.
        #expect(WorkspaceFolder.url(for: "w-123", root: root).lastPathComponent == "w-123")
    }

    @Test func ensure_가_폴더와_context_를_만든다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try WorkspaceFolder.ensure("w1", root: root)

        #expect(FileManager.default.fileExists(atPath: WorkspaceFolder.url(for: "w1", root: root).path))
        #expect(FileManager.default.fileExists(atPath: WorkspaceFolder.contextURL(for: "w1", root: root).path))
    }

    /// **급소.** 앱을 켤 때마다 `ensure` 가 불리는데 사람이 쓴 문서를 덮어쓰면 안 된다.
    @Test func ensure_는_사람이_쓴_context_를_덮어쓰지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try WorkspaceFolder.ensure("w1", root: root)
        try WorkspaceFolder.writeContext("w1", "API 계약은 이렇다",
                                         expecting: WorkspaceFolder.readContext("w1", root: root),
                                         root: root)
        try WorkspaceFolder.ensure("w1", root: root)

        #expect(WorkspaceFolder.readContext("w1", root: root) == .text("API 계약은 이렇다"))
    }

    @Test func 없는_워크스페이스의_context_는_없음이다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkspaceFolder.readContext("없음", root: root) == .missing)
    }

    @Test func 두_워크스페이스가_섞이지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try WorkspaceFolder.ensure("w1", root: root)
        try WorkspaceFolder.ensure("w2", root: root)
        try WorkspaceFolder.writeContext("w1", "하나",
                                         expecting: WorkspaceFolder.readContext("w1", root: root),
                                         root: root)
        try WorkspaceFolder.writeContext("w2", "둘",
                                         expecting: WorkspaceFolder.readContext("w2", root: root),
                                         root: root)

        #expect(WorkspaceFolder.readContext("w1", root: root) == .text("하나"))
        #expect(WorkspaceFolder.readContext("w2", root: root) == .text("둘"))
    }

    // MARK: - context.md 를 잃지 않는다 (최종 리뷰 F2 · F5 · F6)

    /// F6 — 파일은 있는데 못 읽는 것을 "없음" 과 같은 빈 문자열로 돌려주면,
    /// 편집창이 비어 보이고 그대로 저장하면 사람이 쓴 문서가 지워진다.
    @Test func UTF8_이_아닌_context_는_읽을_수_없음이다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        try Data([0xFF, 0xFE, 0xC3, 0x28]).write(to: WorkspaceFolder.contextURL(for: "w1", root: root))

        #expect(WorkspaceFolder.readContext("w1", root: root) == .unreadable)
    }

    @Test func 읽을_수_없는_context_에는_쓰지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let bytes = Data([0xFF, 0xFE, 0xC3, 0x28])
        let url = WorkspaceFolder.contextURL(for: "w1", root: root)
        try bytes.write(to: url)

        #expect(throws: WorkspaceFolder.ContextConflict.self) {
            try WorkspaceFolder.writeContext("w1", "", expecting: .unreadable, root: root)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    /// F2 — 읽어온 뒤 앱 밖(Finder 로 연 편집기)에서 바뀌었으면 덮어쓰지 않는다.
    @Test func 앱_밖에서_바뀐_context_는_덮어쓰지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let base = WorkspaceFolder.readContext("w1", root: root)
        let url = WorkspaceFolder.contextURL(for: "w1", root: root)
        try Data("밖에서 고침".utf8).write(to: url)

        #expect(throws: WorkspaceFolder.ContextConflict.self) {
            try WorkspaceFolder.writeContext("w1", "앱에서 고침", expecting: base, root: root)
        }
        #expect(WorkspaceFolder.readContext("w1", root: root) == .text("밖에서 고침"))
    }

    @Test func 읽어온_뒤_지워진_context_도_되살리지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let base = WorkspaceFolder.readContext("w1", root: root)
        try FileManager.default.removeItem(at: WorkspaceFolder.contextURL(for: "w1", root: root))

        #expect(throws: WorkspaceFolder.ContextConflict.self) {
            try WorkspaceFolder.writeContext("w1", "앱에서 고침", expecting: base, root: root)
        }
    }

    /// F5 — 원자적 쓰기는 임시 파일에 쓰고 rename 한다. 그래서 inode 가 바뀐다.
    /// 제자리 쓰기(inode 유지)는 중간에 죽으면 파일이 잘린 채 남는다.
    @Test func context_는_원자적으로_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let path = WorkspaceFolder.contextURL(for: "w1", root: root).path
        let before = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int

        try WorkspaceFolder.writeContext("w1", "새 글",
                                         expecting: WorkspaceFolder.readContext("w1", root: root),
                                         root: root)

        let after = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int
        #expect(before != nil && before != after)
    }

    /// 저장할 수 없을 때(충돌·읽기 실패) 앱을 끄거나 워크스페이스를 바꾸면 편집 버퍼를
    /// 옆 파일로 남긴다. 원본도 버퍼도 지우지 않는다.
    @Test func 저장_못_한_글은_옆_파일로_남긴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let original = WorkspaceFolder.readContext("w1", root: root)

        let copy = try WorkspaceFolder.writeUnsavedCopy("w1", "버퍼", root: root,
                                                        now: Date(timeIntervalSince1970: 0))

        #expect(copy.deletingLastPathComponent() == WorkspaceFolder.url(for: "w1", root: root))
        #expect(copy.lastPathComponent.hasPrefix("context.unsaved-"))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "버퍼")
        #expect(WorkspaceFolder.readContext("w1", root: root) == original)
    }

    // MARK: - 휴지통 (D-26)

    /// 진짜 휴지통을 어지럽히지 않도록 `remover` 를 바꿔 끼운다.
    @Test func 삭제하면_그_워크스페이스_폴더를_휴지통으로_보낸다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        try WorkspaceFolder.ensure("w2", root: root)

        var trashed: [URL] = []
        try WorkspaceFolder.trash("w1", root: root) { trashed.append($0) }

        #expect(trashed == [WorkspaceFolder.url(for: "w1", root: root)])
    }

    @Test func 폴더가_없으면_아무것도_하지_않는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var called = false
        try WorkspaceFolder.trash("없음", root: root) { _ in called = true }

        #expect(!called)
    }

    @Test func 지시문은_워크스페이스_폴더의_CLAUDE_md_다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        try WorkspaceFolder.writeInstructions("w1", "# 지시", root: root)
        let url = WorkspaceFolder.instructionsURL(for: "w1", root: root)
        #expect(url.lastPathComponent == "CLAUDE.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "# 지시")
    }

    @Test func 조율자_폴더에_두_지시문을_다_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        try WorkspaceFolder.writeInstructions("w1", "# c", kind: .claude, root: root)
        try WorkspaceFolder.writeInstructions("w1", "# x", kind: .codex, root: root)
        #expect(try String(contentsOf: root.appendingPathComponent("w1/CLAUDE.md"), encoding: .utf8) == "# c")
        #expect(try String(contentsOf: root.appendingPathComponent("w1/AGENTS.md"), encoding: .utf8) == "# x")
        #expect(WorkspaceFolder.codexInstructionsURL(for: "w1", root: root).lastPathComponent == "AGENTS.md")
    }

    @Test func context_씨앗은_두_지시문_이름을_적는다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkspaceFolder.ensure("w1", root: root)
        let text = try String(contentsOf: WorkspaceFolder.contextURL(for: "w1", root: root), encoding: .utf8)
        #expect(text.contains("`CLAUDE.md` · `AGENTS.md`"))
    }
}
