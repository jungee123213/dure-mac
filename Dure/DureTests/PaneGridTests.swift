import CoreGraphics
import Foundation
import Testing
@testable import Dure

/// 이슈 #63 · D-51 — 페인 배치 세로 ↔ 2열. 칸 계산과 선택 기억을 고정한다.
/// 뷰 수명(배치를 바꿔도 PTY 가 안 닫힘)은 실물 확인의 몫이다.
struct PaneGridTests {

    let header: CGFloat = 24
    let size = CGSize(width: 801, height: 601)

    func open(_ n: Int) -> [PaneGrid.Item] { Array(repeating: .init(collapsed: false, header: header), count: n) }

    // MARK: - 칸

    @Test func 네_개는_2x2_이고_조율자가_왼쪽_위다() {
        let f = PaneGrid.frames(open(4), in: size, spacing: 1)
        #expect(f == [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 401, y: 0, width: 400, height: 300),
                      CGRect(x: 0, y: 301, width: 400, height: 300), CGRect(x: 401, y: 301, width: 400, height: 300)])
    }

    @Test func 홀수면_마지막은_반_칸이다() {
        let f = PaneGrid.frames(open(3), in: size, spacing: 1)
        #expect(f[2] == CGRect(x: 0, y: 301, width: 400, height: 300))
    }

    @Test func 하나면_반_칸_한_행이다() {
        #expect(PaneGrid.frames(open(1), in: size, spacing: 1) == [CGRect(x: 0, y: 0, width: 400, height: 601)])
    }

    @Test func 행에_펼친_페인이_있으면_접힌_칸도_제자리_같은_크기다() {
        var items = open(4)
        items[1].collapsed = true
        let f = PaneGrid.frames(items, in: size, spacing: 1)
        #expect(f[1] == CGRect(x: 401, y: 0, width: 400, height: 300))
    }

    @Test func 행이_전부_접히면_헤더_높이로_줄고_남은_높이를_펼친_행이_나눈다() {
        var items = open(6)
        items[2].collapsed = true
        items[3] = .init(collapsed: true, header: 30)
        let f = PaneGrid.frames(items, in: size, spacing: 1)
        // 601 - 간격 2 - 접힌 행 30 = 569 → 두 행이 284.5 씩.
        #expect(f[0].height == 284.5 && f[2] == CGRect(x: 0, y: 285.5, width: 400, height: 30))
        #expect(f[4] == CGRect(x: 0, y: 316.5, width: 400, height: 284.5))
    }

    @Test func 홀수_마지막_페인이_접히면_그_행이_준다() {
        // 빈칸은 접힌 것으로 센다.
        var items = open(3) + [PaneGrid.Item.filler]
        items[2].collapsed = true
        let f = PaneGrid.frames(items, in: size, spacing: 1)
        #expect(f[2].height == header && f[3] == CGRect(x: 401, y: 601 - header, width: 400, height: header))
        #expect(f[0].height == 601 - 1 - header)
    }

    @Test func 전부_접히면_헤더_합만큼만_차지한다() {
        let items = open(3).map { PaneGrid.Item(collapsed: true, header: $0.header) } + [.filler]
        #expect(PaneGrid.height(items, proposed: 601, spacing: 1) == header * 2 + 1)
        #expect(PaneGrid.frames(items, in: size, spacing: 1)[2].minY == header + 1)
    }

    @Test func 펼친_행이_있으면_제안받은_높이를_다_쓴다() {
        #expect(PaneGrid.height(open(3), proposed: 601, spacing: 1) == 601)
    }

    @Test func 빈칸은_홀수일_때만_붙인다() {
        #expect(PaneGrid.needsFiller(paneCount: 3) && !PaneGrid.needsFiller(paneCount: 4))
    }

    @Test func 페인이_없으면_칸도_없다() {
        #expect(PaneGrid.frames([], in: size, spacing: 1).isEmpty)
    }

    // MARK: - 선택 기억

    @Test func 처음엔_세로다() {
        #expect(PaneArrangement.saved(in: MemorySettings()) == .stack)
    }

    @Test func 고른_배치를_기억한다() {
        let s = MemorySettings()
        PaneArrangement.remember(.grid, in: s)
        #expect(PaneArrangement.saved(in: s) == .grid)
        #expect(PaneArrangement.grid.toggled == .stack && PaneArrangement.stack.toggled == .grid)
    }

    @Test func 모르는_값이면_세로다() {
        let s = MemorySettings()
        s.set("diagonal", forKey: PaneArrangement.key)
        #expect(PaneArrangement.saved(in: s) == .stack)
    }
}
