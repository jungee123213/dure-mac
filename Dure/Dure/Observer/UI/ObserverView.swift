// Dure/Dure/Observer/UI/ObserverView.swift
import SwiftUI

/// 감시자 창. 스펙 v2 7절.
struct ObserverView: View {
    @Bindable var observer: ObserverStore
    @State private var tab: Tab = .units
    @State private var showingSettings = false

    enum Tab: Hashable { case units, dure, habit, tokens }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("작업").tag(Tab.units)
                    Text("두레 개선 \(count(.dure))").tag(Tab.dure)
                    Text("내 습관 \(count(.habit))").tag(Tab.habit)
                    Text("토큰").tag(Tab.tokens)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Spacer()
                if let id = observer.runningRunID,
                   let unit = observer.units.first(where: { observer.latestRun[$0.id]?.id == id }) {
                    ProgressView().controlSize(.small)
                    Text("\(unit.title) 평가 중").font(.caption).foregroundStyle(.secondary)
                }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }.help("감시자 설정")
            }
            .padding(10)
            notices
            Divider()
            content
            chatPane
        }
        .sheet(isPresented: $showingSettings) { ObserverSettingsSheet(observer: observer) }
        .onAppear { observer.reload() }
        // 창을 닫으면 묻기도 끝난다(스펙 v2 7절). 안 비우면 다시 열 때 같은 --session-id 로 claude 를 또 띄운다.
        .onDisappear { observer.closeChat() }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .units: UnitsView(observer: observer)
        case .dure: BacklogView(observer: observer, bucket: .dure)
        case .habit: BacklogView(observer: observer, bucket: .habit)
        case .tokens: TokenComparisonView(observer: observer)
        }
    }

    /// 묻기 페인은 탭 밖에 둔다 — 탭 안에 두면 탭을 바꿀 때 터미널이 걷혀 대화가 끊긴다(최종 리뷰 F4).
    /// [닫기] 나 다른 작업으로 바꾸면 뷰가 걷히고 그때 claude 도 끝난다(`terminateOnDismantle`).
    @ViewBuilder private var chatPane: some View {
        if let chat = observer.chat {
            Divider()
            HStack {
                Text("리포트에 대해 묻기 — \(observer.units.first { $0.id == chat.unitID }?.title ?? "작업")")
                    .font(.caption.bold()).lineLimit(1)
                Spacer()
                Button("닫기") { observer.closeChat() }.controlSize(.small)
            }.padding(.horizontal, 8).padding(.top, 4)
            TerminalPane(script: chat.script, terminateOnDismantle: true).id(chat.unitID).frame(minHeight: 240)
        }
    }

    private func count(_ b: BacklogBucket) -> Int {
        observer.backlog.filter { $0.bucket == b && BacklogRules.isOpen($0.state) && $0.observedCount > 0 }.count
    }

    @ViewBuilder private var notices: some View {
        let lines = [observer.ghProblem,
                     observer.formatWarning ? "수집 형식 경고 — 최근 기록에서 읽지 못한 줄이 많습니다. Claude Code 형식이 바뀌었을 수 있습니다." : nil,
                     observer.referenceMissing ? "기준 문서가 없습니다(~/.dure/observer/reference). 평가는 되지만 비교 근거가 약합니다." : nil,
                     observer.referenceExpired ? "기준 문서의 재검토 기한이 지났습니다. 다른 도구 · 스킬 정보가 오래됐을 수 있습니다." : nil,
                     observer.autoRunsToday >= observer.settings.dailyCap ? "오늘 자동 평가 상한(\(observer.settings.dailyCap)회)에 닿았습니다. 남은 것은 내일 이어서 돕니다." : nil,
                     observer.settings.enabled ? nil : "감시자가 꺼져 있습니다."].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) { ForEach(lines, id: \.self) { Text("⚠︎ " + $0).font(.caption) } }
                .padding(.horizontal, 10).padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
