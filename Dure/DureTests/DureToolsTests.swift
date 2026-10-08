import Foundation
import Testing
@testable import Dure

/// 단계 4 — 소켓이 곧 신원이라 **조율자와 레포 페인이 다른 툴을 본다.**
struct DureToolsTests {

    @Test func 조율자_툴_넷() {
        #expect(DureTools.names(for: .orchestrator) == ["dispatch", "workspace", "tasks", "cancel"])
    }

    @Test func 레포_툴_둘() {
        #expect(DureTools.names(for: .repo) == ["report", "ask_orchestrator"])
    }

    @Test func 정의마다_설명과_스키마가_있다() {
        for side in [DureTools.Side.orchestrator, .repo] {
            for t in DureTools.definitions(for: side) {
                #expect((t["description"] as? String)?.isEmpty == false)
                #expect((t["inputSchema"] as? [String: Any])?["type"] as? String == "object")
            }
        }
    }

    @Test func dispatch_는_repo_와_instruction_이_필수다() throws {
        let d = try #require(DureTools.definitions(for: .orchestrator).first { $0["name"] as? String == "dispatch" })
        let req = (d["inputSchema"] as? [String: Any])?["required"] as? [String]
        #expect(req == ["repo", "instruction"])
    }

    @Test func 서버_이름은_권한_규칙과_같다() {
        #expect(DureTools.serverName == "dure")
    }

    // MARK: - 레포 찾기 (Review Focus 4)

    static let repos = [
        Repo(id: "a", workspaceId: "w", path: "/x/MoaMap-Android", label: "android"),
        Repo(id: "i", workspaceId: "w", path: "/x/moamap ios"),
    ]

    @Test(arguments: ["android", "Android", "MoaMap-Android", "/x/MoaMap-Android"])
    func 라벨_폴더명_경로로_찾는다(_ q: String) {
        #expect(DureTools.resolveRepo(q, in: Self.repos)?.id == "a")
    }

    @Test func 공백_경로의_폴더명도_찾는다() {
        #expect(DureTools.resolveRepo("moamap ios", in: Self.repos)?.id == "i")
        #expect(DureTools.resolveRepo("  moamap ios ", in: Self.repos)?.id == "i")
    }

    @Test func 못_찾으면_nil_과_후보_목록() {
        #expect(DureTools.resolveRepo("backend", in: Self.repos) == nil)
        #expect(DureTools.repoCandidates(Self.repos) == "android (/x/MoaMap-Android) · moamap ios (/x/moamap ios)")
    }
}
