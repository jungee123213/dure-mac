import SwiftUI

/// 설계문서 7절 ④ — 조율자가 언제 누구에게 뭘 시켰고 어떻게 됐나. 얇은 타임라인.
/// 취소는 `queued` 에만 — 전달된 것은 페인이 이미 일한다.
struct DispatchHistoryView: View {
    @Bindable var store: DureStore
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("작업 이력").font(.headline)
                    Text("배분 · 보고").font(.caption).foregroundStyle(.secondary)
                }
                // 한 번만 읽는다 — 카드마다 relayHistory() 를 부르면 배분 수만큼 DB 를 읽는다.
                let rows = store.dispatchHistory()
                let grouped = DispatchPresentation.group(relays: store.relayHistory(), dispatchIDs: Set(rows.map(\.id)))
                let answers = DispatchPresentation.group(answers: store.answerHistory(), dispatchIDs: Set(rows.map(\.id)))
                let timeline = Self.timeline(rows, orphans: grouped.orphans, orphanAnswers: answers.orphans)
                if timeline.isEmpty {
                    Text("아직 배분이 없습니다. 조율자에게 할 일을 말하면 여기에 쌓입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(timeline) { item in
                    switch item {
                    case .dispatch(let d): card(d, relays: grouped.byDispatch[d.id] ?? [], answers: answers.byDispatch[d.id] ?? [])
                    case .orphan(let r): orphanRow(r)
                    case .orphanAnswer(let a): orphanAnswerRow(a)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    /// 배분 카드와 고아 relay 를 한 목록에. 둘 다 최신이 위.
    private enum Item: Identifiable {
        case dispatch(Dispatch), orphan(Relay), orphanAnswer(Answer)
        var id: String {
            switch self {
            case .dispatch(let d): "d:\(d.id)"
            case .orphan(let r): "r:\(r.id)"
            case .orphanAnswer(let a): "a:\(a.id)"
            }
        }
        var createdAt: Int {
            switch self {
            case .dispatch(let d): d.createdAt
            case .orphan(let r): r.createdAt
            case .orphanAnswer(let a): a.createdAt
            }
        }
    }

    private static func timeline(_ rows: [Dispatch], orphans: [Relay], orphanAnswers: [Answer]) -> [Item] {
        // 정렬의 안정성은 문서로 보장되지 않으므로 같은 초면 원래 순서(배분 번호 내림차순 · relay 최신순)를 지키게 색인을 같이 비교한다.
        let items = rows.map(Item.dispatch) + orphans.map(Item.orphan) + orphanAnswers.map(Item.orphanAnswer)
        return items.enumerated().sorted { a, b in
            a.element.createdAt != b.element.createdAt ? a.element.createdAt > b.element.createdAt : a.offset < b.offset
        }.map(\.element)
    }

    /// 배분에 묶이지 않은 보고 · 질문 한 줄 — 라벨 · 레포 · 본문 첫 줄.
    private func orphanRow(_ r: Relay) -> some View {
        let repoName = r.repoId.flatMap { id in store.repos.first { $0.id == id }?.displayName } ?? "?"
        let first = r.body.split(separator: "\n").first.map(String.init) ?? ""
        return HStack(alignment: .top, spacing: 6) {
            Text("\(DispatchPresentation.relayLabel(r)) · \(repoName)").font(.caption).bold().foregroundStyle(.secondary)
            Text(first).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Text(DispatchRules.clock(r.createdAt)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 배분에 묶이지 않은 답 한 줄 — 고아 relay 와 같은 모양.
    private func orphanAnswerRow(_ a: Answer) -> some View {
        let repoName = store.repos.first { $0.id == a.repoId }?.displayName ?? "?"
        let first = a.body.split(separator: "\n").first.map(String.init) ?? ""
        return HStack(alignment: .top, spacing: 6) {
            Text("\(DispatchPresentation.answerLabel(a)) · \(repoName)").font(.caption).bold().foregroundStyle(.secondary)
            Text(first).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Text(DispatchRules.clock(a.createdAt)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ d: Dispatch, relays: [Relay], answers: [Answer]) -> some View {
        let repoName = store.repos.first { $0.id == d.repoId }?.displayName ?? "?"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(DispatchPresentation.line(d, repoName: repoName)).font(.caption).bold()
                    .foregroundStyle(color(d.state))
                Spacer(minLength: 0)
                if d.state == .queued {
                    Button("취소") { store.cancelDispatch(d.id) }.font(.caption).buttonStyle(.borderless)
                }
                // 이슈 #24 — 에이전트가 complete 를 잊었을 때. 마지막 답을 결과로 조율자에게 올린다.
                if d.state == .delivered || d.state == .waiting {
                    Button("완료로 닫기") { store.closeDispatch(d.id) }.font(.caption).buttonStyle(.borderless)
                }
                Button(expanded.contains(d.id) ? "접기" : "펼치기") {
                    if expanded.contains(d.id) { expanded.remove(d.id) } else { expanded.insert(d.id) }
                }
                .font(.caption).buttonStyle(.borderless)
            }
            Text(DispatchPresentation.headline(d)).font(.caption).lineLimit(1)
            if let g = DispatchPresentation.gitLine(d) {
                Text(g).font(.caption2).foregroundStyle(.secondary)
            }
            if expanded.contains(d.id) {
                if let t = d.issueTitle, !t.isEmpty {
                    Text("제목").font(.caption2).bold().foregroundStyle(.secondary)
                    Text(t).font(.caption).textSelection(.enabled)
                    if let b = d.issueBody, !b.isEmpty {
                        Text(b).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                }
                Text(d.instruction).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if let r = d.result, !r.isEmpty {
                    Divider()
                    Text(r).font(.caption2).textSelection(.enabled)
                }
            }
            // 이력은 최신이 먼저 온다 — 뒤집어 오래된 것부터 섞는다. 답이 그 질문 바로 다음에 놓인다(설계 6절).
            ForEach(DispatchPresentation.cardRows(relays: relays.reversed(), answers: answers.reversed())) { row in
                HStack(alignment: .top, spacing: 4) {
                    switch row {
                    case .relay(let r):
                        Text("↳ \(DispatchPresentation.relayLabel(r))").font(.caption2).foregroundStyle(.secondary)
                        Text(r.body).font(.caption2).lineLimit(expanded.contains(d.id) ? nil : 1)
                    case .answer(let a):
                        Text("↳ \(DispatchPresentation.answerLabel(a))").font(.caption2).foregroundStyle(.secondary)
                        Text(a.body).font(.caption2).lineLimit(expanded.contains(d.id) ? nil : 1)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(_ s: DispatchState) -> Color {
        switch s {
        case .queued: .orange
        case .delivered: .blue
        case .waiting: .purple
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
