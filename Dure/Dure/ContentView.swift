import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = DureStore()
    /// Step 4 — 훅이 떨어뜨린 이벤트를 소비해 매핑 테이블을 갱신한다.
    @State private var ingestor = EventIngestor()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            terminalStack
        }
        .onAppear {
            store.load()
            if store.workspaces.isEmpty {
                store.addWorkspace(name: "기본 워크스페이스")
            }
            // 터미널을 띄우기 전에 시작한다. 밀린 이벤트를 먼저 훑고 감시를 건다.
            ingestor.start(store: store)
            // 앱이 꺼져 있던 동안 붙은 트랜스크립트 분량을 따라잡는다 (커서가 있어 증분이다).
            store.ingestTranscripts()
        }
    }

    // MARK: - 사이드바 (F1 워크스페이스)

    private var sidebar: some View {
        List {
            Section("워크스페이스") {
                Picker("", selection: Binding(
                    get: { store.selectedWorkspaceID ?? "" },
                    set: { store.selectedWorkspaceID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(store.workspaces) { w in
                        Text(w.name).tag(w.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Section("레포") {
                ForEach(store.visibleRepos) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.displayName).font(.body)
                        Text(repo.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Picker("모델", selection: modelBinding(for: repo)) {
                            Text("기본").tag("")
                            Text("opus").tag("opus")
                            Text("sonnet").tag("sonnet")
                            Text("fable").tag("fable")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption)
                    }
                    .contextMenu {
                        Button("제거", role: .destructive) { store.removeRepo(repo) }
                    }
                }
                Button("레포 폴더 추가…") { pickRepoFolder() }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240)
    }

    private func modelBinding(for repo: Repo) -> Binding<String> {
        Binding(
            get: { repo.model ?? "" },
            set: { store.setModel($0.isEmpty ? nil : $0, for: repo) }
        )
    }

    // MARK: - 터미널 (F16, ADR-13 세로 스택 N-페인)

    private var terminalStack: some View {
        Group {
            if store.visibleRepos.isEmpty {
                ContentUnavailableView(
                    "레포가 없습니다",
                    systemImage: "folder.badge.plus",
                    description: Text("왼쪽에서 레포 폴더를 추가하면 터미널이 열립니다.")
                )
            } else {
                // 높이 균등 고정. 탭 바 없음, 스플리터 없음, 재배치 없음 (ADR-13).
                VStack(spacing: 1) {
                    ForEach(store.visibleRepos) { repo in
                        TerminalPane(repo: repo, sessionID: store.sessionID(for: repo))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: .separatorColor))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - 폴더 선택

    private func pickRepoFolder() {
        guard let wsID = store.selectedWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "추가"
        panel.message = "Claude Code 를 띄울 레포 폴더를 고르세요."
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.addRepo(path: url.path, to: wsID)
            }
        }
    }
}

#Preview {
    ContentView()
}
