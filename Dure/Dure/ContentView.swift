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
            // F8 — 페인이 아직 안 떴어도 브랜치는 보여야 한다.
            store.refreshAllGit()
            // 훅이 놓치는 "사람이 앱 밖에서 한 커밋" 을 메운다 (D-13).
            store.startGitPolling()
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
                        HStack(spacing: 6) {
                            Text(repo.displayName).font(.body)
                            Spacer(minLength: 0)
                            StateChip(state: store.state(forRepo: repo.id))
                        }
                        GitChip(status: store.git[repo.id])
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
                    briefingBar
                    ForEach(store.visibleRepos) { repo in
                        VStack(spacing: 0) {
                            paneHeader(for: repo)
                            if store.hasStarted(repo.id) {
                                // `sessionID` 는 출발할 때 처음 만들어진다. 훅이 발화하기 전에
                                // agent 행이 있어야 하므로 스폰 직전인 여기가 맞다 (ADR-17).
                                let sessionID = store.sessionID(for: repo)
                                TerminalPane(repo: repo, sessionID: sessionID,
                                             initialPrompt: store.prompt(for: repo.id),
                                             onExit: { _ in store.markDead(sessionID) })
                            } else {
                                waitingToStart(repo)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: .separatorColor))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// F10a — 여기 넣은 문구를 **모든 페인이 같이 받고 출발한다.**
    /// 비워두고 시작해도 된다. 그러면 그냥 `claude` 만 뜬다.
    private var briefingBar: some View {
        HStack(spacing: 8) {
            TextField("브리핑 (비워도 됩니다) — 모든 터미널이 이 문장으로 출발합니다",
                      text: $store.broadcastPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.callout)
            Button("전체 시작") { store.startAll() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.hasUnstartedPanes)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 아직 안 뜬 페인. **자동 기동을 하지 않는다** — 브리핑을 넣을 틈이 있어야 하기 때문이다.
    private func waitingToStart(_ repo: Repo) -> some View {
        VStack(spacing: 10) {
            Text("시작 대기")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("이 페인만 시작") { store.start(repo) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 페인이 여러 개 쌓이므로 어느 레포인지와 지금 상태를 한 줄로 보여준다.
    /// 탭·스플리터를 두지 않는다는 결정(ADR-13)과 별개로, 이름표는 있어야 구분된다.
    private func paneHeader(for repo: Repo) -> some View {
        HStack(spacing: 8) {
            Text(repo.displayName).font(.caption).bold()
            StateChip(state: store.state(forRepo: repo.id))
            GitChip(status: store.git[repo.id])
            Spacer()
            if let model = repo.model {
                Text(model).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
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

/// F4 — 상태를 한눈에. `대기중`(사람 답을 기다림)만 눈에 띄게 한다.
struct StateChip: View {
    let state: AgentState?

    var body: some View {
        if let state {
            Text(state.label)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch state {
        case .waiting: .orange     // 사람이 붙어야 하는 유일한 상태
        case .running: .blue
        case .done:    .green
        case .dead:    .secondary
        default:       .secondary
        }
    }
}

/// F8 — 브랜치명과 변경 파일 수. **읽기만 한다** (ADR-4).
///
/// 값이 없으면 아무것도 그리지 않는다. 못 읽은 것을 `clean` 으로 보이면 거짓말이다 (D-13).
struct GitChip: View {
    let status: GitStatus?

    var body: some View {
        if let status {
            HStack(spacing: 4) {
                Image(systemName: status.isDetached ? "arrow.triangle.branch" : "arrow.branch")
                    .font(.caption2)
                Text(status.isDetached ? "detached" : status.branch)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !status.isClean {
                    // dirty 는 개수만. 파일 이름도 diff 도 보여주지 않는다 (ADR-15).
                    Text("●\(status.dirtyCount)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(status.isClean ? .secondary : .primary)
        }
    }
}

#Preview {
    ContentView()
}
