// Dure/Dure/Observer/UI/ObserverSettingsSheet.swift
import SwiftUI

struct ObserverSettingsSheet: View {
    @Bindable var observer: ObserverStore
    @Environment(\.dismiss) private var dismiss
    @State private var excludesText = ""
    @State private var confirmReset = false
    @State private var resetMessage: String?

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
            Section("데이터") {
                Button("수집 다시 하기", role: .destructive) { confirmReset = true }
                    .disabled(observer.resetting || observer.runningRunID != nil)
                Text(observer.runningRunID != nil ? "평가가 돌고 있는 동안은 할 수 없습니다. 끝난 뒤에 눌러 주세요."
                     : "작업 단위 · 턴을 지우고 Claude 기록(jsonl)에서 처음부터 다시 모읍니다. 수집 규칙을 고친 뒤 옛 결과를 바로잡을 때 씁니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let resetMessage { Text(resetMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("수집을 다시 할까요?", isPresented: $confirmReset) {
            Button("모두 지우고 다시 수집", role: .destructive) {
                Task {
                    switch await observer.resetAll() {
                    case .success(.done): resetMessage = "다시 수집을 시작했습니다."
                    case .success(.refusedRunning): resetMessage = "평가가 돌고 있어 하지 못했습니다."
                    case .failure(let e): resetMessage = "실패: \(e.localizedDescription)"
                    }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("평가 기록 · 백로그 · 피드백도 모두 지워집니다. 기준 문서와 설정은 그대로입니다.")
        }
        .padding(16).frame(width: 520)
        .onAppear { excludesText = observer.settings.excludes.joined(separator: ", ") }
        .toolbar { Button("완료") { saveExcludes(); dismiss() } }
    }

    private func saveExcludes() {
        observer.settings.excludes = excludesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
