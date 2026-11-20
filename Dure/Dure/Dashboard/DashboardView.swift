import SwiftUI

/// 설계문서 7절 — 터미널과 화면을 바꿔 쓰는 대시보드.
///
/// **전체 폭을 쓰는 이유는 `context.md` 를 여기서 편집하기 때문이다.**
/// 사이드바(240px)나 하단 서랍으로는 문서를 고칠 만한 폭이 안 나온다.
struct DashboardView: View {
    @Bindable var store: DureStore
    /// 이슈 #35 — ③ 사용량 · 툴 에러 상위의 기간과 결과.
    @State private var period: UsageStats.Period = .week
    @State private var usage: UsageStats.Summary?
    @State private var latestUsage = LatestOnly()

    /// 이 값이 바뀌면 사용량을 다시 센다 — 기간 · 워크스페이스 · 감시자 데이터(수집이 끝날 때마다 오름).
    private struct UsageKey: Hashable {
        var period: UsageStats.Period
        var workspace: String?
        var data: Int
    }

    var body: some View {
        HSplitView {
            contextPane
                .frame(minWidth: 320)
            mapPane
                .frame(minWidth: 260)
            DispatchHistoryView(store: store)
                .frame(minWidth: 260)
        }
    }

    // MARK: - ② 컨텍스트 문서 (사람이 씀)

    private var contextPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("공유 컨텍스트").font(.headline)
                Text("context.md").font(.caption).foregroundStyle(.secondary)
                Spacer()
                // 최종 리뷰 F3 — 저장을 안 누른 채 두면 끌 때 사라지는 줄 모른다. 보이게 한다.
                if store.contextIsDirty {
                    Text("● 저장 안 됨").font(.caption).foregroundStyle(.orange)
                }
                Button("저장") { store.saveContext() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.contextProblem != nil)
            }
            if let problem = store.contextProblem { problemBanner(problem) }
            // 조율자의 판단이 이상하면 여기를 고쳐서 교정한다 (설계문서 4절).
            TextEditor(text: $store.contextText)
                .font(.system(.body, design: .monospaced))
                .border(Color(nsColor: .separatorColor))
                // F6 — 못 읽은 파일 위에 새 글을 쓰게 두면 그 글은 저장할 곳이 없다.
                .disabled(store.contextProblem == .unreadable)
        }
        .padding(12)
        // F2 — 편집이 없으면 앱 밖에서 고친 글을 가져온다. 편집 중이면 손대지 않는다.
        .onAppear { store.refreshContextIfUnedited() }
    }

    /// 저장을 막았을 때. **버퍼를 버리는 것은 사람이 [다시 불러오기] 를 누를 때뿐이다.**
    private func problemBanner(_ problem: DureStore.ContextProblem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                switch problem {
                case .changedOutside:
                    Text("context.md 가 앱 밖에서 바뀌었습니다. 덮어쓰지 않았습니다.")
                    Text("다시 불러오면 여기서 고친 내용은 버려집니다. 필요하면 먼저 복사해 두세요.")
                        .font(.caption).foregroundStyle(.secondary)
                case .unreadable:
                    Text("context.md 를 읽을 수 없습니다 (UTF-8 이 아니거나 권한 문제). 저장을 막았습니다.")
                    Text("Finder 에서 파일을 확인한 뒤 다시 불러오세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
            Button("다시 불러오기") { store.reloadContext() }
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - ① 워크스페이스 지도 (앱이 만듦)

    private var mapPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("워크스페이스 지도").font(.headline)
                    Text("workspace.md").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("기간", selection: $period) {
                        Text("오늘").tag(UsageStats.Period.today)
                        Text("7일").tag(UsageStats.Period.week)
                        Text("전체").tag(UsageStats.Period.all)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text("사용량 · 툴 에러는 감시자 수집 기준 — 이 워크스페이스 레포에서 일어난 것(터미널 포함)")
                    .font(.caption2).foregroundStyle(.secondary)
                if let limit = CodexLimitText.line(store.codexLimit.limits, blocked: store.codexLimit.isBlocked) {
                    Text(limit)
                        .font(.caption)
                        .foregroundStyle(store.codexLimit.isBlocked ? Color.orange : Color.secondary)
                }
                // 조율자는 레포가 없어도 있다 — 지도 맨 위에 상태를 보인다.
                if let ws = store.selectedWorkspaceID {
                    let orch = PaneTarget.orchestrator(workspaceID: ws)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Label("조율자", systemImage: "person.3").font(.body).bold()
                            StateChip(state: store.state(for: orch))
                            Spacer(minLength: 0)
                            if store.hasStarted(orch) {
                                Text("열림").font(.caption2).foregroundStyle(.green)
                            }
                        }
                        usageLine(usage?.orchestrator)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                if store.visibleRepos.isEmpty {
                    Text("등록된 레포가 없습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.visibleRepos) { repo in
                    repoCard(repo)
                }
                toolErrors
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .task(id: UsageKey(period: period, workspace: store.selectedWorkspaceID, data: store.observer?.dataVersion ?? 0)) {
            if let fresh = await latestUsage.run({ await store.usageSummary(period: period) }) { usage = fresh }
        }
    }

    private func repoCard(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(repo.displayName).font(.body).bold()
                GitChip(status: store.git[repo.id])
                Spacer(minLength: 0)
                if store.hasStarted(.repo(repo)) {
                    Text("열림").font(.caption2).foregroundStyle(.green)
                }
            }
            if let role = repo.role, !role.isEmpty {
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
            Text(repo.path)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            usageLine(usage?.byRepoPath[repo.path])

            if let commits = store.git[repo.id]?.recentCommits, !commits.isEmpty {
                // 조율자가 "남이 뭘 바꿨나" 를 읽는 값이다. 사람도 같은 걸 본다.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(commits, id: \.self) { c in
                        Text(c).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - ③ 사용량 · 툴 에러 상위 (이슈 #35)

    private func usageLine(_ u: UsageStats.Usage?) -> some View {
        let u = u ?? UsageStats.Usage()
        return Text("토큰 \(UsageStats.compact(u.tokens)) · 툴 \(UsageStats.compact(u.tools))")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private var toolErrors: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("툴 에러 상위").font(.subheadline).bold().padding(.top, 4)
            if let usage, !usage.errors.isEmpty {
                ForEach(Array(usage.errors.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(e.source).font(.caption).bold()
                        Text(e.head.isEmpty ? "(내용 없음)" : e.head)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(e.count)회").font(.caption).monospacedDigit()
                    }
                }
            } else {
                Text("툴 에러 없음").font(.caption).foregroundStyle(.secondary)
            }
            if let n = usage?.bareExitExcluded, n > 0 {
                Text("Bash 종료 코드 실패 \(n)건 제외").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
