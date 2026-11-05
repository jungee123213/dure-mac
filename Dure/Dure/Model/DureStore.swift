import Foundation
import GRDB
import Observation

/// 부록 A5 — 상태를 소유하는 단일 지점.
/// 설계문서는 "액터 하나"라고 적었으나, SwiftUI 뷰와 SwiftTerm 뷰가 모두 `@MainActor`
/// 이므로 **메인액터를 그 단일 소유자로 삼는다.** 별도 액터를 두면 뷰로 넘어올 때마다
/// hop 이 생기고 얻는 것이 없다. DB 접근만 `DatabaseQueue` 로 직렬화된다.
@MainActor
@Observable
final class DureStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var repos: [Repo] = []
    /// 페인별 에이전트. F4 상태가 여기 산다.
    private(set) var agents: [Agent] = []
    /// ADR-17 의 매핑 결과. Step 5(F6·F7) 가 여기 `transcriptPath` 를 직접 읽는다.
    private(set) var ccSessions: [CCSession] = []
    /// 페인별 토큰 합계. `/clear` 로 갈라진 cc_session 들을 **합산한다** (부록 A4 주석).
    private(set) var usageByAgent: [String: UsageTotals] = [:]
    /// 레포별 git 상태. F8. 읽기 실패는 값을 지우지 않는다 (D-13).
    private(set) var git = GitStatusCache()
    /// `context.md` 의 내용. 대시보드가 편집한다.
    var contextText: String = ""
    /// `contextText` 를 읽어온 워크스페이스. 다른 워크스페이스의 글을 엉뚱한 곳에 쓰지 않기 위한 표식이다.
    @ObservationIgnored private var contextLoadedFor: String?
    /// 읽어온(또는 마지막으로 저장한) 시점의 글. 이것과 달라야 "편집됨" 이다.
    /// **관측 대상이다** — 대시보드의 "저장 안 됨" 표시가 이 값으로 바뀐다 (최종 리뷰 F3).
    private var contextAsLoaded: String = ""
    /// 편집을 시작할 때 디스크에서 읽은 결과. 저장할 때 디스크가 **이것과 같아야만** 쓴다 (F2).
    @ObservationIgnored private var contextBase: WorkspaceFolder.ContextRead = .missing

    /// 저장을 막은 이유. 대시보드가 띄운다.
    enum ContextProblem: Equatable {
        /// 읽어온 뒤 앱 밖(Finder 로 연 편집기 등)에서 바뀌었다 (F2).
        case changedOutside
        /// 파일은 있는데 읽지 못했다 (F6). 빈 글로 덮어쓰면 문서가 사라진다.
        case unreadable
    }
    private(set) var contextProblem: ContextProblem?

    /// 저장 안 된 편집이 있는가.
    var contextIsDirty: Bool { contextText != contextAsLoaded }
    /// 이미 출발한 페인의 키(`PaneTarget.key`). **자동 기동을 하지 않으므로** 여기 없는 페인은 아직 안 떴다.
    private(set) var startedPanes: Set<String> = []
    /// 이슈 #20 — 접힌 페인의 키. 메모리에만 둔다(앱을 다시 켜면 전부 펼침).
    /// 접어도 터미널은 트리에 남는다 — 높이 0 · 히트테스트 끔 · 첫 응답자 놓기 (D-27 과 같은 처리).
    private(set) var collapsedPanes: Set<String> = []
    /// 페인을 시작하지 못한 이유(페인 키 → 문장). 조율자 준비(설정·지시문 쓰기) 실패가 여기 온다.
    /// 권한이나 지시문이 빠진 채로 뜨면 git 읽기마다 승인이 뜨거나 메시지 범위 규칙이 없다 — 그래서 아예 안 띄운다.
    private(set) var paneProblems: [String: String] = [:]
    /// 이슈 #30 — 레포 경로로 연 바깥 터미널(iTerm). 두레가 관할하지 않고 창 번호만 기억한다.
    let shells = RepoShells()
    /// 단계 4 — 배분 흐름. 스토어 상태는 클로저로 넘긴다(테스트 가능성).
    @ObservationIgnored private(set) lazy var dispatcher = Dispatcher(
        db: AppDatabase.queue, inbox: LiveInbox(),
        lookups: .init(
            // 레포 **id** 를 받는다. 모르는 id 면 "안 뜬 페인" 으로 답해 큐에 남긴다.
            repoPane: { [unowned self] id in
                guard let r = self.repos.first(where: { $0.id == id }) else {
                    return .init(started: false, state: nil, claudeSessionID: nil)
                }
                return self.paneView(.repo(r))
            },
            orchestratorPane: { [unowned self] in self.paneView(.orchestrator(workspaceID: $0)) },
            repoName: { [unowned self] id in self.repos.first { $0.id == id }?.displayName ?? "?" }))
    /// 페인별 MCP 소켓 서버. 페인이 살아 있는 동안만.
    @ObservationIgnored private var mcpServers: [String: MCPServer] = [:]
    /// 스폰 스크립트 캐시. `initialPrompt` 는 큐 항목을 `delivered` 로 찍는 쓰기라 뷰가 그릴 때마다 부르지 않는다 — 페인당 한 번.
    @ObservationIgnored private var launchScripts: [String: String] = [:]
    /// 이슈 #23 — 감시자. 훅 두 가지만 넘긴다(수집 계기 · 실제 승인 프롬프트). 앱이 붙여 준다.
    @ObservationIgnored weak var observer: ObserverStore?
    /// 배분 기록이 바뀔 때 올린다. 대시보드 ④ · 페인 배지가 이걸 본다 (DB 를 관측할 수 없어서).
    private(set) var dispatchVersion = 0
    var selectedWorkspaceID: String? {
        willSet {
            // 저장을 안 누르고 워크스페이스를 바꾸면 openWorkspaceFolder 가 contextText 를
            // 덮어써 편집이 사라진다. 나가는 쪽 워크스페이스에 먼저 저장한다.
            // 폴더가 없으면(deleteWorkspace 가 폴더를 지운 뒤 선택을 nil 로 바꾼다) 쓰지 않는다 —
            // 쓰면 지운 워크스페이스 폴더가 되살아난다. 충돌 검사(F2)도 같은 경로를 탄다.
            saveContextBeforeLeaving()
        }
        didSet {
            refreshAllGit()
            openWorkspaceFolder()
        }
    }

    /// 페인 키 → `DURE_SESSION` (ADR-14). 페인 하나당 UUID 하나.
    /// 뷰가 다시 그려져도 같은 값이어야 훅이 보내는 값과 앱의 매핑이 어긋나지 않는다.
    /// **뷰 갱신을 유발하면 안 되므로** 관측 대상에서 뺀다.
    @ObservationIgnored private var sessionIDs: [String: String] = [:]

    /// F8 의 저빈도 폴링 (D-13). 뷰 갱신을 유발할 값이 아니다.
    @ObservationIgnored private var gitPollTask: Task<Void, Never>?

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// 현재 워크스페이스의 레포들. 터미널 페인은 이 순서대로 세로로 쌓인다 (ADR-13).
    var visibleRepos: [Repo] {
        guard let id = selectedWorkspaceID else { return [] }
        return repos(in: id)
    }

    /// 한 워크스페이스의 레포들. 숨긴 층(D-27)도 보이는 층과 같은 순서로 그린다.
    func repos(in workspaceID: String) -> [Repo] {
        repos.filter { $0.workspaceId == workspaceID }
    }

    /// 한 워크스페이스의 페인. **조율자가 맨 위**이고 레포가 그 아래로 쌓인다 (스펙 6절).
    func panes(in workspaceID: String) -> [PaneTarget] {
        [.orchestrator(workspaceID: workspaceID)] + repos(in: workspaceID).map(PaneTarget.repo)
    }

    var visiblePanes: [PaneTarget] {
        guard let id = selectedWorkspaceID else { return [] }
        return panes(in: id)
    }

    /// D-27 — 뷰 트리에 남길 워크스페이스 층.
    var paneLayers: [PaneLayout.Layer] {
        let started = Set(workspaces.map(\.id).filter { ws in
            panes(in: ws).contains { startedPanes.contains($0.key) }
        })
        return PaneLayout.layers(workspaceIDs: workspaces.map(\.id),
                                 selected: selectedWorkspaceID,
                                 startedWorkspaceIDs: started)
    }

    func load() {
        do {
            let (ws, rs) = try AppDatabase.queue.read { db in
                (try Workspace.order(Column("name")).fetchAll(db),
                 try Repo.order(Column("path")).fetchAll(db))
            }
            workspaces = ws
            repos = rs
            ccSessions = try AppDatabase.queue.read {
                try CCSession.order(Column("started_at")).fetchAll($0)
            }
            if selectedWorkspaceID == nil { selectedWorkspaceID = ws.first?.id }
        } catch {
            NSLog("[Dure] load 실패: \(error)")
        }
    }

    @discardableResult
    func addWorkspace(name: String, defaultAgentKind: AgentKind = .claude) -> Workspace? {
        do {
            let w = try AppDatabase.queue.write {
                try WorkspaceOps.create(name: name, defaultAgentKind: defaultAgentKind, in: $0)
            }
            load()
            // didSet 의 openWorkspaceFolder 가 폴더와 context.md 를 만든다 (Task 5).
            selectedWorkspaceID = w.id
            return w
        } catch {
            NSLog("[Dure] addWorkspace 실패: \(error)")
            return nil
        }
    }

    func renameWorkspace(_ workspaceID: String, to name: String) {
        do {
            try AppDatabase.queue.write { try WorkspaceOps.rename(workspaceID, to: name, in: $0) }
            load()
            // workspace.md 제목이 워크스페이스 이름이다.
            refreshWorkspaceDoc(for: workspaceID)
        } catch {
            NSLog("[Dure] renameWorkspace 실패: \(error)")
        }
    }

    /// 지금 claude 가 살아 있는 페인이 속한 워크스페이스. 삭제를 막는 근거다 (D-26).
    /// 상태가 아직 nil 인 것(막 띄워 훅이 안 온 것)도 살아 있는 것으로 친다.
    var runningWorkspaceIDs: Set<String> {
        Set(workspaces.map(\.id).filter { ws in
            panes(in: ws).contains { startedPanes.contains($0.key) && state(for: $0) != .dead }
        })
    }

    func deletionImpact(of workspaceID: String) -> WorkspaceOps.Impact? {
        try? AppDatabase.queue.read { try WorkspaceOps.impact(of: workspaceID, in: $0) }
    }

    /// 확인창을 띄우기 **전에** 막을 이유가 있는지. nil 이면 지울 수 있다.
    func deletionRefusal(for workspaceID: String) -> WorkspaceOps.Refusal? {
        do {
            try AppDatabase.queue.read {
                try WorkspaceOps.checkDeletable(workspaceID, runningWorkspaceIDs: runningWorkspaceIDs, in: $0)
            }
            return nil
        } catch let refusal as WorkspaceOps.Refusal {
            return refusal
        } catch {
            NSLog("[Dure] 삭제 가능 여부 확인 실패: \(error)")
            return nil
        }
    }

    func deleteWorkspace(_ workspaceID: String) throws {
        let keys = panes(in: workspaceID).map(\.key)
        try AppDatabase.queue.write {
            try WorkspaceOps.delete(workspaceID, runningWorkspaceIDs: runningWorkspaceIDs, in: $0)
        }
        // DB 가 지워진 **뒤에만** 폴더를 옮긴다. 순서가 반대면 DB 실패 시 문서만 사라진다 (D-26).
        do { try WorkspaceFolder.trash(workspaceID) }
        catch { NSLog("[Dure] 워크스페이스 폴더 휴지통 이동 실패: \(error)") }
        // 이미 죽은 페인들의 흔적. 층(D-27)도 이것으로 정리된다.
        for key in keys {
            startedPanes.remove(key)
            sessionIDs[key] = nil
        }
        if selectedWorkspaceID == workspaceID { selectedWorkspaceID = nil }
        // 선택이 비었으면 load 가 첫 워크스페이스를 고른다.
        load()
    }

    func addRepo(path: String, to workspaceID: String) {
        let r = Repo(workspaceId: workspaceID, path: path, label: nil, model: nil, role: nil)
        do {
            try AppDatabase.queue.write { try r.insert($0) }
            load()
            // git 을 읽기 전에도 레포 줄이 지도에 있어야 한다. git 이 끝나면 refreshGit 이 한 번 더 쓴다.
            refreshWorkspaceDoc(for: workspaceID)
            refreshGit(for: r)
        } catch {
            // path 가 UNIQUE 라 이미 등록된 폴더면 여기로 온다.
            NSLog("[Dure] addRepo 실패(중복 가능): \(error)")
        }
    }

    func removeRepo(_ repo: Repo) {
        do {
            _ = try AppDatabase.queue.write { try repo.delete($0) }
            load()
            // 지운 레포가 지도에 남으면 조율자가 없는 레포를 찾는다.
            refreshWorkspaceDoc(for: repo.workspaceId)
        } catch {
            NSLog("[Dure] removeRepo 실패: \(error)")
        }
    }

    // MARK: - F2 세션 아이덴티티 브리지 (ADR-17)

    /// 페인의 `DURE_SESSION`. 없으면 만들면서 `agent` 행을 함께 넣는다.
    ///
    /// **훅이 발화하기 전에 행이 있어야 한다.** `cc_session` 이 `agent` 를 참조하므로,
    /// 스폰보다 늦게 등록하면 첫 `SessionStart` 가 외래키에서 튕긴다.
    /// 그래서 뷰가 세션ID를 묻는 시점(스폰 직전)에 같이 만든다.
    func sessionID(for target: PaneTarget, kind: AgentKind = .claude) -> String {
        if let existing = sessionIDs[target.key] { return existing }

        let uuid = UUID().uuidString
        sessionIDs[target.key] = uuid
        let agent = Agent(dureSession: uuid,
                          workspaceId: target.workspaceID,
                          repoId: target.repo?.id,
                          agentKind: kind.rawValue,
                          state: .started,
                          // 앱이 모델을 정하지 않는다. 실제 모델은 SessionStart 훅이 cc_session 에 남긴다.
                          model: nil,
                          startedAt: Int(Date().timeIntervalSince1970),
                          endedAt: nil)
        do {
            try AppDatabase.queue.write { try agent.insert($0) }
            agents.append(agent)
        } catch { NSLog("[Dure] agent 등록 실패: \(error)") }
        return uuid
    }

    /// 훅 이벤트 하나를 반영한다. 부록 A2.
    /// **무엇을 할지 정하는 판단은 `AgentStateMachine` 에 있다.** 여기는 실행만 한다.
    func apply(_ event: HookEvent) {
        let current = agents.first { $0.dureSession == event.dureSession }?.state
        let reaction = AgentStateMachine.reaction(to: event, current: current)

        if reaction.bridgeSession { bridgeSession(event) }
        if let next = reaction.next { setState(next, for: event.dureSession) }
        // 단계 4 — 배분 흐름에 훅을 알린다. 판단은 Dispatcher 안의 DispatchRules.
        // setState **뒤에** 부른다 — Dispatcher 가 읽는 페인 상태가 이미 done/started 여야 큐가 흐른다.
        // 옛 세션(다시 시작하기 전의 죽은 세션)의 늦은 훅은 거른다 — 새 세션에 간 배분을 옛 Stop 이 닫으면 안 된다.
        // `current` 는 이벤트 **전** 상태다. dead 는 setState 가 되살리지 않으므로 전후가 같다.
        if let target = paneTarget(forSession: event.dureSession),
           DispatchRules.acceptsHook(current: current, sessionOfPane: sessionIDs[target.key],
                                     eventSession: event.dureSession) {
            var touchedDispatch = true
            switch (event.ev, target) {
            case ("Stop", .repo(let r)):
                dispatcher.didStop(repoID: r.id, lastMessage: event.lastAssistantMessage)
            case ("Stop", .orchestrator(let ws)):
                dispatcher.didStopOrchestrator(workspaceID: ws)
            case ("SessionStart", .repo(let r)):
                dispatcher.didStart(repoID: r.id, session: event.ccSessionID, source: event.source)
            case ("SessionStart", .orchestrator(let ws)):
                dispatcher.didStartOrchestrator(workspaceID: ws)
            default: touchedDispatch = false
            }
            // SessionStart 로 흘러간 배분도 대시보드 ④ · 페인 배지에 바로 보이게. 배분과 무관한 훅(툴 사용 등)은
            // 화면을 다시 그리게 하지 않는다.
            if touchedDispatch { dispatchVersion += 1 }
        }
        if reaction.ingestTranscript { ingestTranscripts(for: event.dureSession) }
        // 감시자는 두레 밖 세션까지 30초 틱으로 읽지만, 두레 페인의 턴이 끝난 순간은 여기서 바로 안다.
        if event.ev == "Stop" { observer?.collectSoon() }
        if reaction.refreshGit, let repo = repo(for: event.dureSession) { refreshGit(for: repo) }

        switch reaction.alert {
        case .waiting(let message):
            // 두레 페인의 승인 프롬프트는 추정이 아니라 실제 값이다 — 감시자 다이제스트가 턴에 귀속한다.
            if let cc = currentSession(for: event.dureSession)?.ccSessionId {
                observer?.recordPermissionPrompt(ccSessionID: cc)
            }
            Notifier.post(title: WorkspaceSummary.alertTitle(
                              workspace: workspaceName(for: event.dureSession),
                              repo: paneName(forSession: event.dureSession),
                              suffix: "답을 기다립니다"),
                          body: message, dureSession: event.dureSession)
        case .done:
            Notifier.post(title: WorkspaceSummary.alertTitle(
                              workspace: workspaceName(for: event.dureSession),
                              repo: paneName(forSession: event.dureSession),
                              suffix: "작업 완료"),
                          body: "응답이 끝났습니다.", dureSession: event.dureSession)
        case nil:
            break
        }
    }

    /// `SessionStart` → `cc_session` 한 행. `/clear` 는 새 행을 만든다 (1:N).
    /// 판정 로직은 `SessionBridge` 에 있다 (인메모리 DB 로 테스트하기 위해 분리).
    private func bridgeSession(_ event: HookEvent) {
        do {
            let outcome = try AppDatabase.queue.write { try SessionBridge.apply(event, in: $0) }
            switch outcome {
            case .recorded:
                ccSessions = try AppDatabase.queue.read {
                    try CCSession.order(Column("started_at")).fetchAll($0)
                }
            case .unknownAgent:
                NSLog("[Dure] 모르는 dure_session=\(event.dureSession). 건너뜀")
            case .missingFields:
                NSLog("[Dure] SessionStart 에 session_id/transcript_path 가 없다. 무시")
            }
        } catch {
            NSLog("[Dure] cc_session 기록 실패: \(error)")
        }
    }

    // MARK: - F4 상태 (Step 6)

    /// 페인의 현재 상태. 사이드바·페인 헤더가 읽는다.
    func state(for target: PaneTarget) -> AgentState? {
        guard let session = sessionIDs[target.key] else { return nil }
        return agents.first { $0.dureSession == session }?.state
    }

    /// 그 페인을 실제로 띄운 CLI. agent 행에서 읽는다.
    private func agentKind(for target: PaneTarget) -> AgentKind? {
        guard let session = sessionIDs[target.key],
              let agent = agents.first(where: { $0.dureSession == session }) else { return nil }
        return AgentKind(rawValue: agent.agentKind)
    }

    /// 알림 제목에 쓸 페인 이름. 조율자는 "조율자".
    /// repo_id 가 nil 인 agent 행은 조율자뿐이라(Task 1 v5) 그것으로 가른다.
    func paneName(forSession dureSession: String) -> String {
        guard let agent = agents.first(where: { $0.dureSession == dureSession }) else { return "에이전트" }
        guard let repoId = agent.repoId else { return "조율자" }
        return repos.first { $0.id == repoId }?.displayName ?? "에이전트"
    }

    /// 사이드바 워크스페이스 목록에 실을 숫자 (D-27). 조율자 페인도 센다.
    func summary(for workspaceID: String) -> WorkspaceSummary.Counts {
        let states = panes(in: workspaceID)
            .filter { startedPanes.contains($0.key) }
            .map { state(for: $0) }
        return WorkspaceSummary.counts(states)
    }

    /// agent 행의 workspace_id 로 찾는다 — 조율자는 레포를 거쳐 찾을 수 없다.
    private func workspaceName(for dureSession: String) -> String? {
        guard let agent = agents.first(where: { $0.dureSession == dureSession }) else { return nil }
        return workspaces.first { $0.id == agent.workspaceId }?.name
    }

    private func repo(for dureSession: String) -> Repo? {
        guard let agent = agents.first(where: { $0.dureSession == dureSession }),
              let repoId = agent.repoId else { return nil }
        return repos.first { $0.id == repoId }
    }

    /// 훅의 세션 → 페인. 상태와 무관하게 agent 행만 본다 — 조율자는 repo_id 가 nil 이다.
    private func paneTarget(forSession dureSession: String) -> PaneTarget? {
        guard let agent = agents.first(where: { $0.dureSession == dureSession }) else { return nil }
        if let repoId = agent.repoId { return repos.first { $0.id == repoId }.map(PaneTarget.repo) }
        return .orchestrator(workspaceID: agent.workspaceId)
    }

    /// **`dead` 는 훅이 아니라 PTY 종료로 들어온다** (ADR-13 — 앱이 PTY 를 소유한다).
    /// `SessionEnd` 훅을 쓰지 않는 이유는 1차 훅 목록에 없고, 프로세스 종료가 더 확실해서다.
    func markDead(_ dureSession: String) {
        // 아래에서 sessionIDs 를 지우면 키로는 워크스페이스를 찾을 수 없어 agent 행에서 먼저 잡는다.
        let ws = agents.first { $0.dureSession == dureSession }?.workspaceId
        setState(.dead, for: dureSession, endedNow: true)
        // 이슈 #14 — 끝난 페인은 시작 대기로 되돌린다 (레포 · 조율자 공통, #16). 남겨두면 죽은 터미널에 묶여
        // `이 페인만 시작` 도 무시되고 앱을 껐다 켜야 했다. 기록(agent 행·토큰)은 DB 에 남는다.
        // 다시 시작하면 `sessionID(for:)` 가 새 DURE_SESSION 과 새 agent 행을 만든다.
        guard let key = PaneReset.paneToReset(exitedSession: dureSession,
                                              sessionIDs: sessionIDs) else { return }
        // 단계 4 — 죽은 페인의 소켓을 닫고, 열려 있던 배분은 실패로 닫는다. 다시 시작하면 새 스크립트를 만든다.
        closeMCP(for: key)
        launchScripts[key] = nil
        if let r = repo(for: dureSession) {
            dispatcher.didDie(repoID: r.id)
        } else if case .orchestrator(let w)? = paneTarget(forSession: dureSession) {
            // 전달 뒤 Stop 을 기다리던 표식을 지운다 — 남겨두면 다시 시작한 조율자에게 아무것도 안 간다.
            dispatcher.didDieOrchestrator(workspaceID: w)
        }
        dispatchVersion += 1
        startedPanes.remove(key)
        sessionIDs[key] = nil
        // 이슈 #20 — 접힌 채 끝나면 시작 버튼이 숨어 있다. 시작 대기 화면이 보이게 편다.
        collapsedPanes.remove(key)
        // "지금 페인이 열려 있음" 이 지도에서 빠져야 한다.
        if let ws { refreshWorkspaceDoc(for: ws) }
    }

    private func setState(_ next: AgentState, for dureSession: String, endedNow: Bool = false) {
        guard var agent = agents.first(where: { $0.dureSession == dureSession }) else {
            // 앱 밖 세션은 훅이 발화하지 않지만, 앱을 다시 깐 뒤 남은 이벤트가 들어올 수 있다.
            return
        }
        // 죽은 페인은 되살리지 않는다. 종료 후 도착한 늦은 이벤트가 상태를 되돌리면 안 된다.
        guard agent.state != .dead else { return }

        agent.state = next
        if endedNow { agent.endedAt = Int(Date().timeIntervalSince1970) }
        do {
            try AppDatabase.queue.write { try agent.update($0) }
            if let i = agents.firstIndex(where: { $0.dureSession == dureSession }) {
                agents[i] = agent
            }
        } catch {
            NSLog("[Dure] 상태 갱신 실패: \(error)")
        }
    }

    // MARK: - F6 · F7 (Step 5)

    /// 트랜스크립트에서 **새로 붙은 줄만** 읽어 반영한다.
    /// `dureSession` 을 주면 그 페인만, 없으면 전부 (앱 시작 시 밀린 분량 따라잡기).
    func ingestTranscripts(for dureSession: String? = nil) {
        let targets = dureSession.map { id in ccSessions.filter { $0.dureSession == id } }
            ?? ccSessions
        guard !targets.isEmpty else { return }
        do {
            try AppDatabase.queue.write { db in
                for session in targets { try TranscriptIngestor.ingest(session, in: db) }
            }
            refreshUsage()
        } catch {
            NSLog("[Dure] 트랜스크립트 반영 실패: \(error)")
        }
    }

    private func refreshUsage() {
        do {
            let rows = try AppDatabase.queue.read { try TokenUsage.fetchAll($0) }
            var byCCSession: [String: [TokenUsage]] = [:]
            for row in rows { byCCSession[row.ccSessionId, default: []].append(row) }

            var byAgent: [String: [TokenUsage]] = [:]
            for session in ccSessions {
                byAgent[session.dureSession, default: []] += byCCSession[session.ccSessionId] ?? []
            }
            usageByAgent = byAgent.mapValues(UsageTotals.of)
        } catch {
            NSLog("[Dure] 사용량 집계 실패: \(error)")
        }
    }

    /// 한 페인의 현재 세션. `/clear` 로 여러 개가 쌓이면 **가장 최근 것**이 현재다 (부록 A4).
    func currentSession(for dureSession: String) -> CCSession? {
        ccSessions.filter { $0.dureSession == dureSession }.max { $0.startedAt < $1.startedAt }
    }

    // MARK: - 단계 4 배분

    private func paneView(_ target: PaneTarget) -> Dispatcher.PaneView {
        let session = sessionIDs[target.key]
        return .init(started: hasStarted(target), state: state(for: target),
                     claudeSessionID: session.flatMap { currentSession(for: $0)?.ccSessionId })
    }

    func queueCount(for target: PaneTarget) -> Int {
        _ = dispatchVersion
        guard let r = target.repo else { return 0 }
        return dispatcher.queueCount(repoID: r.id)
    }

    func dispatchHistory() -> [Dispatch] {
        _ = dispatchVersion
        guard let ws = selectedWorkspaceID else { return [] }
        return dispatcher.history(workspaceID: ws)
    }

    func relayHistory() -> [Relay] {
        _ = dispatchVersion
        guard let ws = selectedWorkspaceID else { return [] }
        return dispatcher.relays(workspaceID: ws)
    }

    func cancelDispatch(_ id: String) {
        guard let ws = selectedWorkspaceID else { return }
        _ = try? dispatcher.cancel(.id(id), workspaceID: ws)
        dispatchVersion += 1
    }

    /// 이슈 #24 — 대시보드 ④ [완료로 닫기].
    func closeDispatch(_ id: String) {
        guard let ws = selectedWorkspaceID else { return }
        _ = try? dispatcher.closeByHuman(id, workspaceID: ws)
        dispatchVersion += 1
    }

    /// 페인의 MCP 소켓을 연다. 스폰보다 **먼저** — `nc` 가 기동하자마자 붙는다.
    private func openMCP(for target: PaneTarget, sessionID: String) throws {
        guard MCPSocketPath.ncExists() else { throw MCPSocketPath.Problem.ncMissing }
        var path = MCPSocketPath.path(forSession: sessionID)
        if mcpServers.values.contains(where: { $0.path == path }) {
            // 앞 8자가 겹치는 드문 경우 — 전체 UUID 로.
            path = MCPSocketPath.dir().appendingPathComponent("\(sessionID.lowercased()).sock").path
        }
        try MCPSocketPath.check(path)
        try FileManager.default.createDirectory(at: MCPSocketPath.dir(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let side: DureTools.Side = target.repo == nil ? .orchestrator : .repo
        let tools = DureTools.definitions(for: side)
        let key = target.key
        let server = MCPServer(path: path) { [weak self] line, reply in
            // 소켓 큐 → 메인. 툴의 뜻은 스토어 상태를 읽어야 한다.
            // 바깥 클로저의 weak var 를 그대로 쓰면 동시 실행 코드에서 가변 캡처가 된다 — 캡처 목록으로 복사한다.
            Task { @MainActor [weak self] in
                guard let self else { reply(nil); return }
                let out = MCPHandler.respond(toLine: line, tools: tools, serverName: DureTools.serverName) { call in
                    self.handleTool(call, side: side, paneKey: key)
                }
                reply(out)
            }
        }
        try server.start()
        mcpServers[key] = server
    }

    private func handleTool(_ call: MCPToolCall, side: DureTools.Side, paneKey: String) -> MCPToolResult {
        guard let target = panesByKey[paneKey] else { return .init(text: "페인을 찾을 수 없다.", isError: true) }
        let ws = target.workspaceID
        let ctx = DureToolHost.Context(
            workspaceID: ws, repos: repos(in: ws), repoID: target.repo?.id,
            workspaceMarkdown: { [weak self] in
                guard let self else { return "" }
                return (try? String(contentsOf: WorkspaceFolder.mapURL(for: ws), encoding: .utf8)) ?? self.workspaceName(id: ws)
            },
            // canStart 는 기본값(폴더가 있나)을 쓴다.
            paneState: { [weak self] id in
                guard let self, let r = self.repos.first(where: { $0.id == id }) else { return nil }
                return self.state(for: .repo(r))?.label
            })
        let r = DureToolHost.call(call, side: side, context: ctx, dispatcher: dispatcher)
        dispatchVersion += 1
        return r
    }

    /// 키 → 페인. 소켓 콜백이 키만 들고 온다.
    private var panesByKey: [String: PaneTarget] {
        var m: [String: PaneTarget] = [:]
        for w in workspaces { for p in panes(in: w.id) { m[p.key] = p } }
        return m
    }

    private func mcpSocketPath(for target: PaneTarget) -> String? { mcpServers[target.key]?.path }

    private func closeMCP(for key: String) {
        mcpServers[key]?.stop()
        mcpServers[key] = nil
    }

    // MARK: - 페인 시작

    /// **앱을 켜도 `claude` 는 저절로 뜨지 않는다.** 원래 이유(브리핑을 넣을 틈)는 D-30 으로
    /// 사라졌지만, 어떤 페인을 언제 띄울지는 사람이 정한다.
    func hasStarted(_ target: PaneTarget) -> Bool { startedPanes.contains(target.key) }

    /// 지금 띄울 수 있는가. 레포는 폴더가 있어야 한다 — 없으면 띄워봐야 `cd` 에서 끝난다(이슈 #10).
    /// 조율자는 항상 true — 준비 실패는 `start(_:)` 에서 잡아 `paneProblems` 에 남긴다(다시 누르면 다시 시도).
    func canStart(_ target: PaneTarget) -> Bool {
        switch target {
        case .repo(let r): r.folderExists
        case .orchestrator: true
        }
    }

    /// 페인 하나를 출발시킨다. 이미 떠 있으면 아무것도 하지 않는다 —
    /// 진행 중인 작업을 재시작으로 날리지 않기 위해서다.
    func start(_ target: PaneTarget) {
        // 버튼을 잠그지만 여기서도 막는다 (이슈 #10).
        guard !startedPanes.contains(target.key), canStart(target) else { return }
        // 준비 실패를 canStart 로 막지 않는다 — 실패는 시작을 눌렀을 때 생기고, 다시 누르면 다시 시도해야 한다.
        if case .orchestrator(let ws) = target {
            do {
                try prepareOrchestrator(ws)
                paneProblems[target.key] = nil
            } catch {
                paneProblems[target.key] = "조율자를 준비하지 못했습니다: \(error.localizedDescription)"
                return
            }
        }
        // agent 행을 먼저 만든다(ADR-17) — 소켓 이름도 이 세션 id 에서 나온다.
        // workspace.md 의 "열려 있음 (X)" 도 이 행의 agentKind 를 읽는다 (최종 리뷰 F4).
        let sessionID = sessionID(for: target)
        do {
            try openMCP(for: target, sessionID: sessionID)
            paneProblems[target.key] = nil
        } catch {
            paneProblems[target.key] = "MCP 소켓을 열지 못했습니다: \((error as? MCPSocketPath.Problem)?.message ?? error.localizedDescription)"
            return
        }
        // 지난 기동의 스크립트가 남아 있으면 새 소켓·기동 프롬프트가 빠진 채 뜬다.
        launchScripts[target.key] = nil
        startedPanes.insert(target.key)
        // "지금 페인이 열려 있음" 이 지도에 반영돼야 한다.
        refreshWorkspaceDoc(for: target.workspaceID)
    }

    /// 조율자를 띄우기 직전에 폴더·지시문·권한 설정을 쓴다. 레포가 추가·삭제됐을 수 있어 매번 쓴다.
    private func prepareOrchestrator(_ workspaceID: String) throws {
        guard let ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        try WorkspaceFolder.ensure(workspaceID)
        let members = repos(in: workspaceID).filter(\.folderExists)
        try WorkspaceFolder.writeInstructions(workspaceID, OrchestratorDoc.render(
            workspaceName: ws.name,
            sessionPrefix: SessionName.prefix(workspaceName: ws.name, workspaceID: ws.id),
            repos: members.map { .init(name: $0.displayName, path: $0.path) }))
        try SessionSettings.writeOrchestrator(workspaceID, repoPaths: LaunchPlan.repoPaths(members))
    }

    private func workspaceName(id: String) -> String {
        workspaces.first { $0.id == id }?.name ?? ""
    }

    /// 페인이 실행할 셸 스크립트. 레포 페인과 조율자의 차이(cwd · 설정 · 이름 · `--add-dir`)는 여기서만 갈린다.
    func launchScript(for target: PaneTarget, sessionID: String) -> String {
        // 뷰가 그릴 때마다 불린다. 기동 프롬프트는 큐에서 꺼내는 일이라 페인당 한 번만 만든다.
        if let cached = launchScripts[target.key] { return cached }
        let wsName = workspaceName(id: target.workspaceID)
        let script: String
        let prompt: String?
        switch target {
        case .repo(let r):
            prompt = dispatcher.initialPrompt(forRepo: r.id)
            script = Spawn.script(cwd: r.path, sessionID: sessionID,
                                  settingsPath: SessionSettings.repoPaneURL().path,
                                  sessionName: SessionName.repo(workspaceName: wsName, workspaceID: r.workspaceId,
                                                                repoName: r.displayName),
                                  initialPrompt: prompt,
                                  mcpSocket: mcpSocketPath(for: target))
        case .orchestrator(let ws):
            prompt = dispatcher.initialPrompt(forOrchestrator: ws)
            script = Spawn.script(cwd: WorkspaceFolder.url(for: ws).path, sessionID: sessionID,
                                  settingsPath: SessionSettings.orchestratorURL(ws).path,
                                  sessionName: SessionName.orchestrator(workspaceName: wsName, workspaceID: ws),
                                  addDirs: LaunchPlan.repoPaths(repos(in: ws)),
                                  initialPrompt: prompt,
                                  mcpSocket: mcpSocketPath(for: target))
        }
        launchScripts[target.key] = script
        // 기동 프롬프트가 큐를 꺼냈으면(`delivered` 로 찍었으면) 대시보드 ④ · 배지가 따라와야 한다. 그런데 이 함수는
        // 뷰의 body 안에서 불린다 — 거기서 관측값을 바꾸면 SwiftUI 가 "그리는 중 상태 변경" 으로 경고하고 다시 그리기를
        // 되풀이할 수 있다(RoleField 와 같은 이유). 다음 런루프로 미룬다. 캐시가 있어 페인당 한 번뿐이다.
        if prompt != nil { DispatchQueue.main.async { [weak self] in self?.dispatchVersion += 1 } }
        return script
    }

    // MARK: - 이슈 #20 접기

    func isCollapsed(_ target: PaneTarget) -> Bool { collapsedPanes.contains(target.key) }

    func toggleCollapsed(_ target: PaneTarget) {
        collapsedPanes = PaneLayout.toggled(target.key, in: collapsedPanes)
    }

    /// 보이는 워크스페이스의 레포 페인만 일괄로. 조율자는 그대로.
    func toggleAllReposCollapsed() {
        collapsedPanes = PaneLayout.toggledAllRepos(repoKeys: visibleRepoKeys, in: collapsedPanes)
    }

    var allVisibleReposCollapsed: Bool {
        PaneLayout.allReposCollapsed(repoKeys: visibleRepoKeys, collapsed: collapsedPanes)
    }

    /// 조율자까지 전부 접혔다 — 빈 공간에 안내를 띄운다.
    func allPanesCollapsed(in workspaceID: String) -> Bool {
        PaneLayout.allCollapsed(keys: panes(in: workspaceID).map(\.key), collapsed: collapsedPanes)
    }

    private var visibleRepoKeys: [String] {
        visiblePanes.compactMap { $0.repo == nil ? nil : $0.key }
    }

    /// 지금 보이는 워크스페이스의 페인(조율자 포함)을 한 번에 띄운다 (`전체 시작`, ⌘↩).
    func startAll() {
        for target in visiblePanes { start(target) }
    }

    /// 아직 안 뜬 페인이 하나라도 있는가. 버튼을 잠그는 데 쓴다.
    var hasUnstartedPanes: Bool {
        // 띄울 수 없는 페인(폴더 없는 레포)은 셈에서 뺀다. 안 그러면 그것 하나 때문에 `전체 시작` 이 영영 켜져 있다.
        visiblePanes.contains { !startedPanes.contains($0.key) && canStart($0) }
    }

    // MARK: - 워크스페이스 문서 (조율자 단계 1)

    /// 폴더를 만들고 `context.md` 를 읽어온다. 워크스페이스를 열 때 한 번.
    func openWorkspaceFolder() {
        guard let id = selectedWorkspaceID else { return }
        do { try WorkspaceFolder.ensure(id) }
        catch { NSLog("[Dure] 워크스페이스 폴더 준비 실패: \(error)") }
        // ensure 가 실패해도 읽는다. 안 읽으면 편집창에 **이전 워크스페이스의 글**이 남는다.
        loadContext(id)
        refreshWorkspaceDoc(for: id)
    }

    /// 디스크에서 다시 읽는다. **편집 중인 글은 버려진다** — 사람이 [다시 불러오기] 를
    /// 눌렀을 때와 편집이 없을 때만 부른다.
    func reloadContext() {
        guard let id = selectedWorkspaceID else { return }
        loadContext(id)
    }

    /// 대시보드를 열 때 부른다. 편집이 없으면 앱 밖에서 고친 글을 가져온다 (F2).
    func refreshContextIfUnedited() {
        guard !contextIsDirty else { return }
        reloadContext()
    }

    private func loadContext(_ id: String) {
        let read = WorkspaceFolder.readContext(id)
        contextBase = read
        switch read {
        case .text(let text):
            contextText = text
            contextProblem = nil
        case .missing:
            contextText = ""
            contextProblem = nil
        case .unreadable:
            // 빈 편집창을 보여주되 저장은 막는다. 빈 글로 덮어쓰면 문서가 사라진다 (F6).
            contextText = ""
            contextProblem = .unreadable
        }
        contextAsLoaded = contextText
        contextLoadedFor = id
    }

    /// 저장했으면 true. 충돌이거나 못 읽은 파일이면 **쓰지 않고** false (F2 · F6).
    @discardableResult
    func saveContext() -> Bool {
        guard let id = selectedWorkspaceID, contextLoadedFor == id,
              contextProblem == nil else { return false }
        do {
            try WorkspaceFolder.writeContext(id, contextText, expecting: contextBase)
            contextBase = .text(contextText)
            contextAsLoaded = contextText
            return true
        } catch WorkspaceFolder.ContextConflict.changedOutside {
            contextProblem = .changedOutside
            return false
        } catch {
            NSLog("[Dure] context.md 저장 실패: \(error)")
            return false
        }
    }

    /// 워크스페이스를 바꾸거나 앱을 끄기 직전에 부른다 (F3).
    ///
    /// 저장할 수 없으면(충돌·읽기 실패) 편집 버퍼를 `context.md` 옆 파일로 남긴다.
    /// 이 뒤에 버퍼가 사라지므로, 원본도 버퍼도 잃지 않는 유일한 길이다.
    func saveContextBeforeLeaving() {
        guard let id = selectedWorkspaceID, contextLoadedFor == id, contextIsDirty,
              FileManager.default.fileExists(atPath: WorkspaceFolder.url(for: id).path)
        else { return }
        if saveContext() { return }
        do {
            let copy = try WorkspaceFolder.writeUnsavedCopy(id, contextText)
            NSLog("[Dure] context.md 에 저장하지 못해 편집 내용을 따로 남겼다: \(copy.path)")
        } catch {
            NSLog("[Dure] 저장 못 한 context.md 편집 내용 보존 실패: \(error)")
        }
    }

    /// `workspace.md` 를 다시 쓴다. **선택 여부와 상관없이** — 조율자는 숨겨진 워크스페이스에서도 돈다 (D-27, #16).
    ///
    /// **git 이 갱신될 때마다 함께 부른다.** 조율자가 읽는 지도가 낡으면
    /// "백엔드에 뭐가 바뀌었나" 를 틀리게 답한다.
    func refreshWorkspaceDoc(for workspaceID: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        let lines = repos(in: workspaceID).map { repo in
            WorkspaceDoc.RepoLine(
                name: repo.displayName,
                path: repo.path,
                role: repo.role,
                git: git[repo.id],
                // 최종 리뷰 F4 — 워크스페이스 기본값이 아니라 **실제로 띄운** CLI 를 적는다.
                // 기본 CLI 를 codex 로 바꿔도 페인은 아직 claude 로만 뜬다. 지도가 거짓말을 하면
                // 조율자가 엉뚱한 CLI 를 가정한다.
                openedWith: hasStarted(.repo(repo)) ? agentKind(for: .repo(repo)) : nil,
                instructionsPath: LaunchPlan.instructionsPath(for: repo),
                sessionName: SessionName.repo(workspaceName: workspace.name, workspaceID: workspace.id,
                                              repoName: repo.displayName),
                folderMissing: !repo.folderExists
            )
        }
        let orch = PaneTarget.orchestrator(workspaceID: workspaceID)
        let md = WorkspaceDoc.render(
            name: workspace.name, repos: lines,
            orchestrator: .init(sessionName: SessionName.orchestrator(workspaceName: workspace.name,
                                                                      workspaceID: workspace.id),
                                openedWith: hasStarted(orch) ? agentKind(for: orch) : nil))
        do { try WorkspaceFolder.writeMap(workspace.id, md) }
        catch { NSLog("[Dure] workspace.md 쓰기 실패: \(error)") }
    }

    func refreshAllWorkspaceDocs() {
        for w in workspaces { refreshWorkspaceDoc(for: w.id) }
    }

    /// 앱 시작 때. 숨겨진 워크스페이스의 조율자도 낡지 않은 지도를 읽어야 한다.
    func prepareAllWorkspaceFolders() {
        for w in workspaces {
            do { try WorkspaceFolder.ensure(w.id) }
            catch { NSLog("[Dure] 워크스페이스 폴더 준비 실패(\(w.name)): \(error)") }
        }
        refreshAllWorkspaceDocs()
    }

    // MARK: - F8 git 상태 (Step 7)

    /// 한 레포의 git 상태를 다시 읽는다.
    ///
    /// **메인액터에서 `git` 을 부르지 않는다.** MCP 가 많은 큰 레포는 `status` 가
    /// 수백 ms 걸릴 수 있고, 페인 수만큼 곱해지면 30초마다 UI 가 끊긴다.
    func refreshGit(for repo: Repo) {
        let (id, path, ws) = (repo.id, repo.path, repo.workspaceId)
        Task.detached(priority: .utility) {
            let fresh = GitReader.read(at: path)
            await MainActor.run {
                self.git.update(id, with: fresh)
                // 지도가 낡으면 조율자가 틀린 답을 한다.
                self.refreshWorkspaceDoc(for: ws)
            }
        }
    }

    /// 모든 레포 — 숨겨진 워크스페이스의 조율자도 최신 지도를 읽는다 (#16).
    func refreshAllGit() {
        for repo in repos { refreshGit(for: repo) }
    }

    /// D-13 — 훅만으로는 **사람이 앱 밖에서 한 커밋·체크아웃**을 놓친다.
    /// 커밋 직후가 바로 브랜치명을 확인하고 싶은 순간이라, 거기서 틀리면 기능의 의미가 없다.
    func startGitPolling(every seconds: Double = 30) {
        gitPollTask?.cancel()
        gitPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                self.refreshAllGit()
                // 단계 4 — 소켓 쓰기 실패는 훅이 다시 오지 않는다. 이 30초 틱이 유일한 재시도 계기다.
                self.dispatcher.retryPending()
                self.dispatchVersion += 1
            }
        }
    }

    /// 조율자가 읽는 한 줄 설명. `workspace.md` 에 실린다.
    func setRole(_ role: String?, for repo: Repo) {
        var r = repo
        r.role = (role?.isEmpty ?? true) ? nil : role
        do {
            try AppDatabase.queue.write { try r.update($0) }
            load()
            refreshWorkspaceDoc(for: repo.workspaceId)
        } catch { NSLog("[Dure] setRole 실패: \(error)") }
    }

    /// 워크스페이스 기본 CLI. 페인은 시작할 때 이 값을 미리 골라둔다 (설계문서 8절).
    /// **단계 1 에서는 저장만 한다.** 스폰은 아직 claude 고정이라 workspace.md 도 이 값을 쓰지 않는다 (F4).
    func setDefaultAgentKind(_ kind: AgentKind) {
        guard var w = selectedWorkspace else { return }
        w.defaultAgentKind = kind.rawValue
        do {
            try AppDatabase.queue.write { try w.update($0) }
            load()
        } catch { NSLog("[Dure] setDefaultAgentKind 실패: \(error)") }
    }
}

/// 이슈 #16 — 페인을 띄울 때 넘길 것의 순수한 부분. 스토어는 실제 DB·홈을 써서 테스트하기 어렵다.
enum LaunchPlan {

    /// 조율자의 `--add-dir`·git 허용 대상. 폴더가 없는 레포는 뺀다(이슈 #10) —
    /// 넣으면 claude 가 기동에서 실패하거나 없는 경로를 허용한다.
    static func repoPaths(_ repos: [Repo]) -> [String] {
        repos.filter(\.folderExists).map(\.path)
    }

    /// 레포 지시문 경로. 조율자는 자동으로 싣지 않고(D-31 ②) `workspace.md` 의 이 경로를 보고 읽는다.
    static func instructionsPath(for repo: Repo) -> String? {
        let p = URL(fileURLWithPath: repo.path).appendingPathComponent("CLAUDE.md").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
}
