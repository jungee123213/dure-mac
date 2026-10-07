import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = DureStore()
    /// Step 4 — 훅이 떨어뜨린 이벤트를 소비해 매핑 테이블을 갱신한다.
    @State private var ingestor = EventIngestor()
    /// 설계문서 7절 — 터미널과 대시보드를 바꿔 쓴다. 둘을 동시에 보지 않는다.
    @State private var showingDashboard = false

    /// 이슈 #12 — 워크스페이스 관리.
    @State private var workspaceSheet: WorkspaceSheet.Mode?
    @State private var pendingDelete: Workspace?
    @State private var deleteRefusal: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                modeToggle
                ZStack {
                    terminalStack
                    if showingDashboard {
                        DashboardView(store: store)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
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
            // 조율자가 읽을 폴더와 문서를 준비한다 (설계문서 4절).
            store.openWorkspaceFolder()
            store.startGitPolling()
        }
        // 최종 리뷰 F3 — 저장을 안 누르고 끄면 context.md 편집이 사라진다.
        // 같은 충돌 검사(F2)를 거치고, 저장할 수 없으면 옆 파일로 남긴다.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            store.saveContextBeforeLeaving()
        }
        // 창만 닫아도 이 뷰와 store 가 사라진다 (앱은 계속 뜬다).
        .onDisappear { store.saveContextBeforeLeaving() }
    }

    // MARK: - 사이드바 (F1 워크스페이스)

    private var sidebar: some View {
        List {
            Section("워크스페이스") {
                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { store.selectedWorkspaceID ?? "" },
                        set: { store.selectedWorkspaceID = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(store.workspaces) { w in
                            Text(WorkspaceSummary.label(name: w.name, store.summary(for: w.id)))
                                .tag(w.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Button { workspaceSheet = .create } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("새 워크스페이스")

                    Menu {
                        Button("이름 바꾸기…") {
                            if let w = store.selectedWorkspace { workspaceSheet = .rename(w) }
                        }
                        Button("Finder 에서 열기") { revealWorkspaceFolder() }
                        Divider()
                        Button("삭제…", role: .destructive) { requestDelete() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("워크스페이스 관리")
                }

                Picker("기본 CLI", selection: Binding(
                    get: { AgentKind(rawValue: store.selectedWorkspace?.defaultAgentKind ?? "claude") ?? .claude },
                    set: { store.setDefaultAgentKind($0) }
                )) {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                // 최종 리뷰 F4 — 바꿔도 지금은 아무것도 달라지지 않는다는 것을 숨기지 않는다.
                .help("새 페인부터 적용할 값입니다. 지금은 claude 만 띄웁니다.")
                Text("지금은 claude 만 띄웁니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        RoleField(repo: repo) { store.setRole($0, for: repo) }
                        HStack(spacing: 4) {
                            if !repo.folderExists { MissingFolderChip() }
                            Text(repo.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
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
        .sheet(item: $workspaceSheet) { mode in
            WorkspaceSheet(mode: mode) { name, kind in
                switch mode {
                case .create: store.addWorkspace(name: name, defaultAgentKind: kind)
                case .rename(let w): store.renameWorkspace(w.id, to: name)
                }
            }
        }
        .confirmationDialog("워크스페이스를 삭제할까요?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { w in
            Button("삭제", role: .destructive) { performDelete(w) }
            Button("취소", role: .cancel) {}
        } message: { w in
            Text(deleteMessage(for: w))
        }
        .alert("삭제할 수 없습니다",
               isPresented: Binding(get: { deleteRefusal != nil },
                                    set: { if !$0 { deleteRefusal = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(deleteRefusal ?? "")
        }
    }

    private func modelBinding(for repo: Repo) -> Binding<String> {
        Binding(
            get: { repo.model ?? "" },
            set: { store.setModel($0.isEmpty ? nil : $0, for: repo) }
        )
    }

    // MARK: - 터미널 (F16, ADR-13 세로 스택 N-페인)

    private var terminalStack: some View {
        VStack(spacing: 0) {
            if !store.visibleRepos.isEmpty { briefingBar }
            ZStack {
                // D-27 — 시작한 페인이 있는 워크스페이스는 안 보여도 트리에 남긴다.
                // 트리에서 빠지면 SwiftTerm 이 PTY 를 닫아 claude 가 끊긴다.
                ForEach(store.paneLayers) { layer in
                    paneStack(workspaceID: layer.workspaceID, isActive: layer.isActive)
                        .opacity(layer.isActive ? 1 : 0)
                        .allowsHitTesting(layer.isActive)
                        .accessibilityHidden(!layer.isActive)
                        .zIndex(layer.isActive ? 1 : 0)
                }
                if store.visibleRepos.isEmpty {
                    ContentUnavailableView(
                        "레포가 없습니다",
                        systemImage: "folder.badge.plus",
                        description: Text("왼쪽에서 레포 폴더를 추가하면 터미널이 열립니다.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(2)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    /// 한 워크스페이스의 세로 스택. 높이 균등 고정. 탭 바 없음, 스플리터 없음, 재배치 없음 (ADR-13).
    private func paneStack(workspaceID: String, isActive: Bool) -> some View {
        VStack(spacing: 1) {
            ForEach(store.repos(in: workspaceID)) { repo in
                VStack(spacing: 0) {
                    paneHeader(for: repo)
                    if store.hasStarted(repo.id) {
                        // `sessionID` 는 출발할 때 처음 만들어진다. 훅이 발화하기 전에
                        // agent 행이 있어야 하므로 스폰 직전인 여기가 맞다 (ADR-17).
                        let sessionID = store.sessionID(for: repo)
                        TerminalPane(repo: repo, sessionID: sessionID,
                                     initialPrompt: store.prompt(for: repo.id),
                                     isActive: isActive && !showingDashboard,
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

    private var modeToggle: some View {
        HStack {
            Picker("", selection: $showingDashboard) {
                Text("터미널").tag(false)
                Text("대시보드").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
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
                // 최종 리뷰 F1 — 대시보드가 덮고 있어도 이 버튼은 트리에 있어 ⌘↩ 가 먹는다.
                // 그때 뜬 페인은 안 보이는 채로 출발한다. 터미널이 보일 때만 출발시킨다.
                .disabled(!store.hasUnstartedPanes || showingDashboard)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 아직 안 뜬 페인. **자동 기동을 하지 않는다** — 브리핑을 넣을 틈이 있어야 하기 때문이다.
    private func waitingToStart(_ repo: Repo) -> some View {
        VStack(spacing: 10) {
            if repo.folderExists {
                Text("시작 대기")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 이슈 #10 — 왜 못 띄우는지와 어떻게 하면 되는지를 같이 준다.
                Text("레포 폴더를 찾을 수 없습니다")
                    .font(.callout)
                    .foregroundStyle(.red)
                Text(repo.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("폴더를 되돌리거나, 사이드바에서 이 레포를 제거하고 다시 추가하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("이 페인만 시작") { store.start(repo) }
                .disabled(!repo.folderExists)
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
            if !repo.folderExists { MissingFolderChip() }
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

    // MARK: - 워크스페이스 관리 (이슈 #12)

    /// 막을 이유가 있으면 확인창 대신 이유를 보여준다. 확인창까지 갔다가 거절당하면 헷갈린다.
    private func requestDelete() {
        guard let w = store.selectedWorkspace else { return }
        if let refusal = store.deletionRefusal(for: w.id) {
            deleteRefusal = refusal.message
        } else {
            pendingDelete = w
        }
    }

    private func performDelete(_ w: Workspace) {
        do {
            try store.deleteWorkspace(w.id)
        } catch let refusal as WorkspaceOps.Refusal {
            deleteRefusal = refusal.message
        } catch {
            deleteRefusal = "삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// D-26 — 무엇이 사라지고 무엇이 남는지 적는다. **레포 폴더가 지워진다고 오해하기 쉽다.**
    private func deleteMessage(for w: Workspace) -> String {
        let impact = store.deletionImpact(of: w.id)
        let repos = impact?.repos ?? 0
        let sessions = impact?.sessions ?? 0
        return """
        ‘\(w.name)’ 의 레포 등록 \(repos)개와 에이전트 기록 \(sessions)건(토큰·툴 사용량 포함)이 Dure 에서 삭제됩니다.
        레포 폴더와 코드는 삭제되지 않습니다.
        워크스페이스 폴더(context.md 포함)는 휴지통으로 이동합니다.
        """
    }

    /// `~/.dure` 는 숨김 폴더라 Finder 에서 찾기 어렵다.
    private func revealWorkspaceFolder() {
        guard let id = store.selectedWorkspaceID else { return }
        try? WorkspaceFolder.ensure(id)
        NSWorkspace.shared.activateFileViewerSelecting([WorkspaceFolder.url(for: id)])
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

/// 레포 역할 입력란. 조율자가 읽는 한 줄 설명이다 (workspace.md).
///
/// 최종 리뷰 F8 — **키 입력마다 저장하지 않는다.** 저장은 DB 쓰기 → load() → 목록 재생성 →
/// workspace.md 쓰기로 이어지는데, 한글 조합 중에 바인딩 값이 DB 를 돌아 다시 들어오면
/// 조합이 깨진다. 편집은 로컬 상태에 두고 Enter 나 포커스를 잃을 때 한 번 넘긴다.
struct RoleField: View {
    let repo: Repo
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("역할 (예: API 서버)", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .focused($focused)
            .onSubmit(save)
            // ⚠️ 포커스 해제·사라짐은 **SwiftUI 가 화면을 갱신하는 도중에** 온다(예: 페인 시작으로
            // 새 터미널이 포커스를 가져갈 때). 거기서 바로 저장하면 `load()` 가 레포 목록을 통째로
            // 바꿔 레이아웃 계산 중에 데이터가 바뀌고, AttributeGraph 순환 끝에 크래시가 난다.
            // 그래서 갱신이 끝난 다음 차례로 미룬다. 값은 지금 붙잡아 둔다.
            .onChange(of: focused) { _, isFocused in
                if !isFocused { saveLater() }
            }
            .onAppear { text = repo.role ?? "" }
            // 입력 중에 워크스페이스를 바꾸면 포커스 해제보다 뷰가 먼저 사라질 수 있다.
            .onDisappear(perform: saveLater)
            // 다른 경로로 바뀌면 따라간다. 편집 중이면 사람이 치는 글을 덮지 않는다.
            .onChange(of: repo.role) { _, role in
                if !focused { text = role ?? "" }
            }
    }

    private func save() {
        // 바뀐 것이 없으면 DB·문서를 건드리지 않는다.
        guard text != (repo.role ?? "") else { return }
        commit(text)
    }

    /// 화면 갱신 도중에 불리는 경로용. 위 `onChange` 주석 참고.
    private func saveLater() {
        let value = text
        guard value != (repo.role ?? "") else { return }
        DispatchQueue.main.async { commit(value) }
    }
}

/// 이슈 #10 — 등록 뒤 옮겨지거나 지워진 레포 폴더. 이 레포는 시작할 수 없다.
struct MissingFolderChip: View {
    var body: some View {
        Text("폴더 없음")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.red.opacity(0.18), in: Capsule())
            .foregroundStyle(.red)
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
