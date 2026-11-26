import CoreGraphics
import Foundation
import SwiftUI

/// 이슈 #63 · D-51 — 페인 배치. 시작 바 버튼으로 바꾸고 마지막 선택을 기억한다(앱 전체 하나).
/// 화면 상태라 DB 가 아니라 설정에 둔다(`LastWorkspace` 와 같은 이유).
nonisolated enum PaneArrangement: String, CaseIterable, Sendable {
    /// 세로 스택 — 조율자가 맨 위(ADR-13).
    case stack
    /// 2열 격자, 행 우선 — 조율자가 왼쪽 위.
    case grid

    static let key = "paneArrangement"

    var toggled: PaneArrangement { self == .stack ? .grid : .stack }

    /// 처음 실행 · 모르는 값이면 세로.
    static func saved(in settings: SettingsStore) -> PaneArrangement {
        (settings.object(forKey: key) as? String).flatMap(PaneArrangement.init(rawValue:)) ?? .stack
    }

    static func remember(_ arrangement: PaneArrangement, in settings: SettingsStore) {
        settings.set(arrangement.rawValue, forKey: key)
    }
}

/// 2열 격자의 칸 계산. **순수 함수** — 뷰 없이 테스트한다.
///
/// - 행 우선 2열. 페인 수가 홀수면 마지막 페인은 반 칸이고 옆은 빈칸(`filler`)이다.
/// - 접힌 페인은 **제자리**다. 같은 행에 펼친 페인이 있으면 칸 크기도 그대로 — 헤더만 남고 아래는 빈다.
/// - 행이 전부 접히면 그 행은 헤더 높이(행에서 가장 큰 것)로 줄고, 남은 높이를 펼친 행끼리 똑같이 나눈다.
/// - 전부 접히면 헤더 행들만큼만 차지한다 — 아래 안내 문구가 남은 자리를 쓴다.
nonisolated enum PaneGrid {

    static let columns = 2

    struct Item: Equatable, Sendable {
        var collapsed: Bool
        /// 접혔을 때 차지하는 높이(헤더).
        var header: CGFloat
        /// 홀수 페인 옆 빈칸. 접힌 것으로 센다 — 짝인 페인이 접히면 그 행이 줄어야 한다.
        static let filler = Item(collapsed: true, header: 0)
    }

    static func needsFiller(paneCount: Int) -> Bool { paneCount % columns == 1 }

    private static func rows(_ items: [Item]) -> [ArraySlice<Item>] {
        stride(from: 0, to: items.count, by: columns).map { items[$0..<min($0 + columns, items.count)] }
    }

    /// 행이 전부 접혔으면 그 높이, 펼친 페인이 있으면 nil.
    private static func collapsedHeight(_ row: ArraySlice<Item>) -> CGFloat? {
        row.allSatisfy(\.collapsed) ? row.map(\.header).max() ?? 0 : nil
    }

    /// 격자가 차지할 높이. 펼친 행이 있으면 제안받은 높이를 다 쓴다.
    static func height(_ items: [Item], proposed: CGFloat, spacing: CGFloat) -> CGFloat {
        let rows = rows(items)
        guard !rows.isEmpty else { return 0 }
        let fixed = rows.map(collapsedHeight)
        if fixed.contains(where: { $0 == nil }) { return proposed }
        return fixed.compactMap { $0 }.reduce(0, +) + spacing * CGFloat(rows.count - 1)
    }

    /// 항목마다 칸. 원점은 격자 왼쪽 위.
    static func frames(_ items: [Item], in size: CGSize, spacing: CGFloat) -> [CGRect] {
        let rows = rows(items)
        guard !rows.isEmpty else { return [] }
        let fixed = rows.map(collapsedHeight)
        let open = fixed.filter { $0 == nil }.count
        let free = size.height - spacing * CGFloat(rows.count - 1) - fixed.compactMap { $0 }.reduce(0, +)
        let openHeight = open > 0 ? max(0, free) / CGFloat(open) : 0
        let width = max(0, size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

        var out: [CGRect] = []
        var y: CGFloat = 0
        for (r, row) in rows.enumerated() {
            let h = fixed[r] ?? openHeight
            for c in 0..<row.count {
                out.append(CGRect(x: CGFloat(c) * (width + spacing), y: y, width: width, height: h))
            }
            y += h + spacing
        }
        return out
    }
}

/// 2열 격자 `Layout`. 세로 스택(`VStackLayout`)과 `AnyLayout` 으로 바꿔 끼운다 — 같은 자식을 그대로 두므로
/// 배치를 바꿔도 터미널이 새로 만들어지지 않는다(뷰가 다시 만들어지면 SwiftTerm 이 PTY 를 닫는다, D-27).
struct PaneGridLayout: Layout {
    var spacing: CGFloat = 1

    /// 자식이 페인이면 접힘 여부, 빈칸이면 nil.
    struct Collapsed: LayoutValueKey { static let defaultValue: Bool? = nil }

    private func items(_ subviews: Subviews, width: CGFloat) -> [PaneGrid.Item] {
        let column = max(0, width - spacing * CGFloat(PaneGrid.columns - 1)) / CGFloat(PaneGrid.columns)
        return subviews.map { s in
            guard let collapsed = s[Collapsed.self] else { return .filler }
            // 접힌 페인의 이상 높이 = 헤더(몸통은 높이 0 으로 잘린다).
            let header = collapsed ? s.sizeThatFits(.init(width: column, height: nil)).height : 0
            return .init(collapsed: collapsed, header: header)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = proposal.replacingUnspecifiedDimensions()
        return CGSize(width: size.width,
                      height: PaneGrid.height(items(subviews, width: size.width), proposed: size.height, spacing: spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = PaneGrid.frames(items(subviews, width: bounds.width), in: bounds.size, spacing: spacing)
        for (s, f) in zip(subviews, frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                    proposal: .init(width: f.width, height: f.height))
        }
    }
}
