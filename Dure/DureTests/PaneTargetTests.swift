import Foundation
import Testing
@testable import Dure

/// 이슈 #16 — 페인 상태 사전의 키. 레포 id 와 워크스페이스 id 가 같은 공간에서 부딪히면
/// 조율자와 레포 페인이 같은 세션·같은 시작 여부를 공유하게 된다.
struct PaneTargetTests {

    static let repo = Repo(id: "x1", workspaceId: "w1", path: "/r")

    @Test func 레포와_조율자의_키가_다르다() {
        // 레포 id 와 워크스페이스 id 가 같은 문자열이어도 부딪히지 않는다.
        let r = PaneTarget.repo(Repo(id: "same", workspaceId: "w", path: "/r"))
        let o = PaneTarget.orchestrator(workspaceID: "same")
        #expect(r.key != o.key)
    }

    @Test func 레포_페인은_자기_레포의_워크스페이스에_속한다() {
        #expect(PaneTarget.repo(Self.repo).workspaceID == "w1")
        #expect(PaneTarget.repo(Self.repo).repo == Self.repo)
    }

    @Test func 조율자는_레포가_없다() {
        let o = PaneTarget.orchestrator(workspaceID: "w1")
        #expect(o.workspaceID == "w1")
        #expect(o.repo == nil)
    }
}
