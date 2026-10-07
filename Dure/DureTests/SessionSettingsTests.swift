import Foundation
import Testing
@testable import Dure

/// 이슈 #16 · D-31 — 페인 종류별 `--settings`.
/// **급소 둘.** 레포 페인이 세션 간 메시지를 못 쓰는 것, 조율자의 git 허용이 읽기 명령에만 열리는 것.
struct SessionSettingsTests {

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func tempRoot() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dure-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - 레포 페인

    @Test func 레포_페인은_세션_간_메시지를_막는다() throws {
        let o = try Self.object(try SessionSettings.repoPaneJSON())
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String]
        #expect(deny == ["SendMessage", "ListAgents"])
    }

    @Test func 레포_페인에도_훅이_들어간다() throws {
        let hooks = try Self.object(try SessionSettings.repoPaneJSON())["hooks"] as? [String: Any]
        #expect(Set(hooks?.keys.map { $0 } ?? []) == Set(HookBridge.hookEvents))
    }

    // MARK: - 조율자

    @Test func 조율자는_레포마다_읽기_명령_넷만_허용한다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/back", "/a/ios"]))
        let allow = (o["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == [
            "Bash(git -C /a/back log *)", "Bash(git -C /a/back status *)",
            "Bash(git -C /a/back diff *)", "Bash(git -C /a/back show *)",
            "Bash(git -C /a/ios log *)", "Bash(git -C /a/ios status *)",
            "Bash(git -C /a/ios diff *)", "Bash(git -C /a/ios show *)",
        ])
    }

    /// D-31 — 중간 와일드카드와 `git -C:*` 는 쓰기·옵션 끼워 넣기를 연다.
    @Test func 넓은_규칙을_만들지_않는다() throws {
        let rules = SessionSettings.gitReadRules(repoPath: "/a/b")
        #expect(!rules.contains { $0.contains("-C *") || $0.contains("-C:") })
        #expect(rules.allSatisfy { $0.hasPrefix("Bash(git -C /a/b ") })
    }

    @Test func 조율자는_메시지를_막지_않는다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: []))
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(!deny.contains("SendMessage") && !deny.contains("ListAgents"))
    }

    /// D-31 후속 — diff·show·log 의 `--output=<파일>` 은 git 이 파일을 쓴다 (ADR-4).
    @Test func 조율자는_레포마다_output_옵션을_막는다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/back", "/a/ios"]))
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String]
        #expect(deny == ["Bash(git -C /a/back *--output*)", "Bash(git -C /a/ios *--output*)"])
    }

    @Test func output_차단_규칙도_허용_규칙과_같은_경로_토큰을_쓴다() {
        let path = "/a/with space"
        #expect(SessionSettings.gitWriteDenyRules(repoPath: path)
                == ["Bash(git -C \(SessionSettings.gitPathToken(path)) *--output*)"])
    }

    /// Review Focus 2 — 공백·따옴표·한글 경로는 셸에서 인용된 모양으로 실행된다. 규칙도 그 모양이어야 맞는다.
    @Test(arguments: [
        ("/a/plain-dir_1.x", "/a/plain-dir_1.x"),
        ("/a/with space", "'/a/with space'"),
        ("/a/it's", "'/a/it'\\''s'"),
        ("/a/한글", "'/a/한글'"),
    ])
    func 경로_토큰은_셸_인용과_같다(_ path: String, _ token: String) {
        #expect(SessionSettings.gitPathToken(path) == token)
        #expect(SessionSettings.gitReadRules(repoPath: path).first == "Bash(git -C \(token) log *)")
    }

    // MARK: - 파일

    @Test func 조율자_설정은_워크스페이스_폴더_밖에_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try SessionSettings.writeOrchestrator("w1", repoPaths: ["/a/b"], root: root)
        #expect(url == root.appendingPathComponent("settings/orchestrator-w1.json"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!url.path.contains("/workspaces/"))
    }

    @Test func 레포_페인_설정_파일을_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try SessionSettings.writeRepoPane(root: root)
        let data = try Data(contentsOf: SessionSettings.repoPaneURL(root: root))
        #expect((try Self.object(data)["permissions"] as? [String: Any]) != nil)
    }
}
