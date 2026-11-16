import Foundation
import Testing
@testable import Dure

/// 이슈 #38 — 앱을 다시 켜면 마지막에 보던 워크스페이스로 연다.
/// `DureStore` 는 실제 DB 에 묶여 있어 테스트 호스트에서 못 띄운다(#29). 그래서 고르기 · 저장 판단만 여기서 고정한다.
struct LastWorkspaceTests {

    @Test func 저장된_워크스페이스가_있으면_그걸_고른다() {
        #expect(LastWorkspace.pick(saved: "w2", available: ["w1", "w2", "w3"]) == "w2")
    }

    @Test func 저장된_워크스페이스가_지워졌으면_첫_번째를_고른다() {
        #expect(LastWorkspace.pick(saved: "gone", available: ["w1", "w2"]) == "w1")
    }

    @Test func 처음_실행이면_첫_번째를_고른다() {
        #expect(LastWorkspace.pick(saved: nil, available: ["w1", "w2"]) == "w1")
    }

    @Test func 워크스페이스가_없으면_고르지_않는다() {
        #expect(LastWorkspace.pick(saved: "w1", available: []) == nil)
    }

    @Test func 저장한_값을_다시_읽는다() {
        let s = MemorySettings()
        LastWorkspace.remember("w2", in: s)
        #expect(LastWorkspace.saved(in: s) == "w2")
    }

    /// 삭제 직후 선택이 잠깐 nil 이 된다. 그때 지우지 않는다 — 곧 `load()` 가 고른 워크스페이스로 덮어쓴다.
    @Test func 선택이_비면_저장값을_지우지_않는다() {
        let s = MemorySettings()
        LastWorkspace.remember("w1", in: s)
        LastWorkspace.remember(nil, in: s)
        #expect(LastWorkspace.saved(in: s) == "w1")
    }

    @Test func 아무것도_저장하지_않았으면_nil() {
        #expect(LastWorkspace.saved(in: MemorySettings()) == nil)
    }
}
