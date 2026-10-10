// Dure/Dure/Observer/UI/TokenComparisonView.swift
import SwiftUI

/// "두레를 쓰면 토큰이 과하게 드나" — 레포별로 두레 사용 작업과 터미널 전용 작업을 나란히. 추이 · 그래프는 #22.
struct TokenComparisonView: View {
    let observer: ObserverStore
    @State private var rows: [TokenAccounting.RepoComparison] = []
    @State private var unattributed: [TokenAccounting.Unattributed] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이슈 브랜치 작업만 · 청구 기준 토큰(캐시 읽기 제외) · 턴 = 사람 + 배분 받은 턴 · 두레 쪽은 조율자 몫 포함")
                .font(.caption).foregroundStyle(.secondary)
            Table(rows) {
                TableColumn("레포") { Text(($0.repoRoot as NSString).lastPathComponent) }
                TableColumn("터미널 전용") { Text(cell($0.terminal)) }
                TableColumn("두레 사용") { Text(cell($0.dure)) }
                TableColumn("조율자 몫") { Text($0.orchestratorShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—") }
                TableColumn("두레 / 터미널") { r in Text(r.ratio.map { String(format: "%.1f배", $0) } ?? "판단 보류") }
            }
            if !unattributed.isEmpty {
                Text("귀속 안 된 조율자 토큰: " + unattributed.map { "\($0.name ?? $0.workspaceId) \($0.tokens)" }.joined(separator: " · "))
                    .font(.caption)
            }
            Text("어느 쪽이든 작업이 3개 미만이면 배수를 내지 않습니다. 작업 종류(포팅 · 신규 · 버그)가 섞여 있어 참고치입니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("다시 계산") { reload() } }
        }
        .padding(12)
        .onAppear { reload() }
    }

    private func reload() {
        rows = observer.tokenComparison()
        unattributed = observer.unattributedOrchestrator()
    }

    private func cell(_ b: TokenAccounting.Baseline) -> String {
        func n(_ d: Double?) -> String { d.map { String(format: "%.0f", $0) } ?? "—" }
        return "\(b.samples)개 · 턴당 \(n(b.perTurn)) · 줄당 \(n(b.perLine)) (\(b.perLineSamples)개)"
    }
}
