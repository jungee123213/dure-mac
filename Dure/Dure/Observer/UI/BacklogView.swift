// Dure/Dure/Observer/UI/BacklogView.swift
import AppKit
import SwiftUI

struct BacklogView: View {
    @Bindable var observer: ObserverStore
    let bucket: BacklogBucket
    @State private var expanded: Set<String> = []
    @State private var showClosed = false
    @State private var linking: String?
    @State private var linkText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("해결됨 · 무시 · 근거 0 보기", isOn: $showClosed).toggleStyle(.checkbox)
                Spacer()
                Text("정렬: 작업 수 × 심각도 · 오탐이 많으면 아래").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
            List {
                if bucket == .dure {
                    Section("고칠 것") { ForEach(items.filter { $0.kind != "works_well" }) { card($0) } }
                    Section("지킬 것") { ForEach(items.filter { $0.kind == "works_well" }) { card($0) } }
                } else {
                    ForEach(items) { card($0) }
                }
            }
        }
        .alert("이슈 번호", isPresented: Binding(get: { linking != nil }, set: { if !$0 { linking = nil } })) {
            TextField("dure-mac#24", text: $linkText)
            Button("연결") { if let k = linking { observer.setState(k, .issued, linkedIssue: linkText) }; linking = nil }
            Button("취소", role: .cancel) { linking = nil }
        }
    }

    private var items: [BacklogItem] {
        observer.backlog.filter { $0.bucket == bucket && (showClosed || (BacklogRules.isOpen($0.state) && $0.observedCount > 0)) }
    }

    private func card(_ i: BacklogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(i.title).bold()
                if i.state == .reopened { Text("재발").font(.caption2).foregroundStyle(.red) }
                if let l = i.linkedIssue { Text(l).font(.caption2).foregroundStyle(.blue) }
                Spacer()
                Text("관찰 \(i.observedCount)회 · 작업 \(i.unitCount)개 · 심각도 \(i.maxSeverity) · 👍\(i.usefulCount) 👎\(i.falsePositiveCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if expanded.contains(i.key) {
                Text(i.detail).textSelection(.enabled)
                if let s = i.suggestion { Text("제안: \(s)").foregroundStyle(.secondary).textSelection(.enabled) }
                if let a = i.applyText {
                    Text(a).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding(6).background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                }
                ForEach(observer.findings(forKey: i.key).prefix(5)) { f in
                    Text(evidenceLine(f)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let a = i.applyText { Button("복사") { copy(a) } }
                    if bucket == .dure { Button("이슈로 감…") { linkText = ""; linking = i.key } }
                    Button("해결됨") { observer.setState(i.key, .resolved) }
                    Button("무시") { observer.setState(i.key, .dismissed) }
                    if !BacklogRules.isOpen(i.state) { Button("다시 열기") { observer.setState(i.key, .open) } }
                }.controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if expanded.contains(i.key) { expanded.remove(i.key) } else { expanded.insert(i.key) } }
        .opacity(BacklogRules.isOpen(i.state) ? 1 : 0.5)
    }

    private func evidenceLine(_ f: Finding) -> String {
        let title = observer.units.first { $0.id == f.unitId }?.title ?? "?"
        let ev = (try? JSONDecoder().decode([Evidence].self, from: Data(f.evidence.utf8))) ?? []
        return "\(title) — " + ev.map { "\($0.display) “\($0.quote)”" }.joined(separator: " · ")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
