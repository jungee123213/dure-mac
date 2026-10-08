import SwiftUI

/// 설계문서 7절 — 터미널과 화면을 바꿔 쓰는 대시보드.
///
/// **전체 폭을 쓰는 이유는 `context.md` 를 여기서 편집하기 때문이다.**
/// 사이드바(240px)나 하단 서랍으로는 문서를 고칠 만한 폭이 안 나온다.
struct DashboardView: View {
    @Bindable var store: DureStore

    var body: some View {
        HSplitView {
            contextPane
                .frame(minWidth: 320)
            mapPane
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
                }
                // 조율자는 레포가 없어도 있다 — 지도 맨 위에 상태를 보인다.
                if let ws = store.selectedWorkspaceID {
                    let orch = PaneTarget.orchestrator(workspaceID: ws)
                    HStack(spacing: 6) {
                        Label("조율자", systemImage: "person.3").font(.body).bold()
                        StateChip(state: store.state(for: orch))
                        Spacer(minLength: 0)
                        if store.hasStarted(orch) {
                            Text("열림").font(.caption2).foregroundStyle(.green)
                        }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
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
}
