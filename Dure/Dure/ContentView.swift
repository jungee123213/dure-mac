import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = DureStore()
    /// 페인마다 하나씩. 앱이 만드는 DURE_SESSION 값 (ADR-14).
    @State private var sessionIDs: [String: String] = [:]

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
                        TerminalPane(repo: repo, sessionID: sessionID(for: repo))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: .separatorColor))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// 페인 하나당 UUID 하나. 뷰가 다시 그려져도 같은 값을 유지해야
    /// 훅이 보내는 DURE_SESSION 과 앱의 매핑이 어긋나지 않는다 (ADR-17).
    private func sessionID(for repo: Repo) -> String {
        if let existing = sessionIDs[repo.id] { return existing }
        let new = UUID().uuidString
        DispatchQueue.main.async { sessionIDs[repo.id] = new }
        return new
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
