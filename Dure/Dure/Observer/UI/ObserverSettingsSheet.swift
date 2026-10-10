// Dure/Dure/Observer/UI/ObserverSettingsSheet.swift
import SwiftUI

struct ObserverSettingsSheet: View {
    @Bindable var observer: ObserverStore
    @Environment(\.dismiss) private var dismiss
    @State private var excludesText = ""

    var body: some View {
        Form {
            Toggle("감시자 켜기", isOn: $observer.settings.enabled)
            Toggle("PR 이 머지되면 자동 평가", isOn: $observer.settings.autoEvaluate)
            Stepper("자동 평가 최소 턴(사람 + 배분): \(observer.settings.minTurns)", value: $observer.settings.minTurns, in: 1...20)
            Stepper("하루 자동 평가 상한: \(observer.settings.dailyCap)", value: $observer.settings.dailyCap, in: 0...50)
            Toggle("기본 브랜치 · git 밖 작업도 하루가 지나면 자동 평가", isOn: $observer.settings.autoEvaluateDayUnits)
            TextField("제외 경로(쉼표로 구분)", text: $excludesText).onSubmit { saveExcludes() }
            Text("감시자 자신의 폴더와 감시자가 띄운 세션은 늘 제외됩니다. 파일을 고친 작업은 최소 턴과 무관하게 자격이 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 520)
        .onAppear { excludesText = observer.settings.excludes.joined(separator: ", ") }
        .toolbar { Button("완료") { saveExcludes(); dismiss() } }
    }

    private func saveExcludes() {
        observer.settings.excludes = excludesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
