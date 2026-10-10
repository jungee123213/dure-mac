// Dure/Dure/Observer/UI/UnitsView.swift
import SwiftUI

struct UnitsView: View {
    @Bindable var observer: ObserverStore
    @State private var selected: String?
    @State private var selectedRun: String?
    @State private var confirmReplace: String?

    var body: some View {
        HSplitView {
            List(observer.units, selection: $selected) { u in row(u).tag(u.id) }
                .frame(minWidth: 300, idealWidth: 360)
            VStack(spacing: 0) {
                if let id = selected, let u = observer.units.first(where: { $0.id == id }) {
                    detail(u)
                } else {
                    Text("작업을 고르세요").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480)
        }
        .onChange(of: selected) { selectedRun = nil }
        .confirmationDialog("지금 대화를 닫고 새로 열까요?",
                            isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } })) {
            Button("새로 열기") { if let id = confirmReplace { observer.openChat(id) }; confirmReplace = nil }
            Button("취소", role: .cancel) { confirmReplace = nil }
        }
    }

    private func row(_ u: WorkUnit) -> some View {
        let run = observer.latestRun[u.id]
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(u.title).lineLimit(1)
                if observer.isStale(u) { Text("평가 뒤 변경").font(.caption2).foregroundStyle(.orange) }
            }
            HStack(spacing: 6) {
                Text(run.map { statusText($0.status) } ?? "평가 전").font(.caption)
                Text("추정 묶음 · 사람 \(u.humanTurns) · 배분 \(u.peerTurns)").font(.caption).foregroundStyle(.secondary)
                if let c = run?.costUsd { Text(String(format: "API 상당 $%.2f", c)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func detail(_ u: WorkUnit) -> some View {
        let runs = observer.runs(forUnit: u.id)
        let shown = runs.first { $0.id == selectedRun } ?? runs.first { $0.status == .done } ?? runs.first
        HStack {
            Text(u.title).font(.headline)
            if let pr = u.prNumber { Text("PR #\(pr)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if runs.count > 1 {
                Picker("실행", selection: Binding(get: { shown?.id ?? "" }, set: { selectedRun = $0 })) {
                    ForEach(runs) { r in Text("\(statusText(r.status)) · \(r.trigger == .auto ? "자동" : "수동")").tag(r.id) }
                }.frame(maxWidth: 220)
            }
            Button(runs.contains { $0.status == .done } ? "다시 평가" : "평가") { observer.requestEvaluation(u.id) }
                .disabled(runs.contains { $0.status == .queued || $0.status == .running })
            Button("리포트에 대해 묻기") {
                if let open = observer.chat, open.unitID != u.id { confirmReplace = u.id } else { observer.openChat(u.id) }
            }
            .disabled(!runs.contains { $0.status == .done })
        }
        .padding(10)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let r = shown {
                    if r.status == .failed || r.status == .interrupted { Text("평가 실패: \(r.failure ?? "?")").foregroundStyle(.red).textSelection(.enabled) }
                    if r.status == .done, ObserverRules.isStale(unit: u, run: r) {
                        Text("이 평가 뒤에 같은 작업에 새 기록이 있습니다. [다시 평가] 로 최신 상태를 볼 수 있습니다.").font(.caption).foregroundStyle(.orange)
                    }
                    if let report = observer.report(unit: u.id, run: r.id) { MarkdownView(text: report) }
                    let fs = observer.findings(forRun: r.id)
                    if !fs.isEmpty {
                        Divider()
                        Text("지적 평가 — 감시자가 쓸모 있는지의 실측값입니다").font(.caption.bold())
                        ForEach(fs) { f in feedbackRow(f) }
                    }
                } else {
                    Text("아직 평가 전입니다. PR 이 머지되면 자동으로 평가합니다(사람 + 배분 턴 \(observer.settings.minTurns)개 이상 또는 파일 수정).")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func feedbackRow(_ f: Finding) -> some View {
        HStack {
            Text(f.title).lineLimit(1)
            Spacer()
            Button { observer.setFeedback(f.id, f.feedback == .useful ? nil : .useful) } label: {
                Label("유용", systemImage: f.feedback == .useful ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button { observer.setFeedback(f.id, f.feedback == .falsePositive ? nil : .falsePositive) } label: {
                Label("오탐", systemImage: f.feedback == .falsePositive ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
        }
        .controlSize(.small)
    }

    private func statusText(_ s: RunStatus) -> String {
        switch s {
        case .queued: "평가 대기"
        case .running: "평가 중"
        case .done: "평가됨"
        case .failed: "실패"
        case .interrupted: "중단됨"
        case .cancelled: "취소됨"
        }
    }
}
