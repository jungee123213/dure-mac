import Foundation
import Testing
@testable import Dure

/// 이슈 #12 · D-27 — 안 보이는 워크스페이스에서 돌거나 기다리는 페인을 놓치지 않게 한다.
struct WorkspaceSummaryTests {

    @Test func 죽은_페인은_세지_않는다() {
        let c = WorkspaceSummary.counts([.running, .dead])
        #expect(c == .init(open: 1, waiting: 0))
    }

    /// 막 띄워서 훅이 아직 안 온 페인(nil)도 열려 있다.
    @Test func 상태가_아직_없는_페인도_열림이다() {
        #expect(WorkspaceSummary.counts([nil]).open == 1)
    }

    @Test func 대기는_열림에도_들어간다() {
        let c = WorkspaceSummary.counts([.waiting, .done, .started])
        #expect(c == .init(open: 3, waiting: 1))
    }

    @Test func 아무것도_없으면_이름만_적는다() {
        #expect(WorkspaceSummary.label(name: "모바일", .init()) == "모바일")
    }

    @Test func 열림과_대기를_이어_적는다() {
        #expect(WorkspaceSummary.label(name: "모바일", .init(open: 2, waiting: 1)) == "모바일 · 열림 2 · 대기 1")
    }

    @Test func 대기가_없으면_대기는_생략한다() {
        #expect(WorkspaceSummary.label(name: "모바일", .init(open: 2, waiting: 0)) == "모바일 · 열림 2")
    }

    @Test func 알림_제목에_워크스페이스_이름을_붙인다() {
        #expect(WorkspaceSummary.alertTitle(workspace: "모바일", repo: "app", suffix: "작업 완료")
                == "모바일 · app — 작업 완료")
    }

    /// 매핑이 아직 없거나 레포가 지워졌으면 예전 제목 그대로.
    @Test func 워크스페이스를_모르면_레포_이름만_쓴다() {
        #expect(WorkspaceSummary.alertTitle(workspace: nil, repo: "app", suffix: "작업 완료")
                == "app — 작업 완료")
    }
}
