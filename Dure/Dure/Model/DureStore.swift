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
    /// F10a — 출발할 때 모든 페인이 함께 받을 브리핑. 비어 있어도 된다.
    var broadcastPrompt: String = ""
    /// 이미 출발한 레포. **자동 기동을 하지 않으므로** 여기 없는 페인은 아직 안 떴다.
    private(set) var startedRepos: Set<String> = []
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

    /// 페인 하나당 UUID 하나 (ADR-14 의 `DURE_SESSION`).
    /// 뷰가 다시 그려져도 같은 값이어야 훅이 보내는 값과 앱의 매핑이 어긋나지 않는다.
    /// **뷰 갱신을 유발하면 안 되므로** 관측 대상에서 뺀다.
    @ObservationIgnored private var sessionIDs: [String: String] = [:]

    /// F8 의 저빈도 폴링 (D-13). 뷰 갱신을 유발할 값이 아니다.
    @ObservationIgnored private var gitPollTask: Task<Void, Never>?

    /// 출발할 때 실제로 넘긴 브리핑. 입력란은 그 뒤에 바뀔 수 있으므로 따로 붙잡아둔다.
    @ObservationIgnored private var promptByRepo: [String: String] = [:]

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

    /// D-27 — 뷰 트리에 남길 워크스페이스 층.
    var paneLayers: [PaneLayout.Layer] {
        let started = Set(repos.filter { startedRepos.contains($0.id) }.map(\.workspaceId))
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
            refreshWorkspaceDoc()
        } catch {
            NSLog("[Dure] renameWorkspace 실패: \(error)")
        }
    }

    /// 지금 claude 가 살아 있는 레포. 워크스페이스 삭제를 막는 근거다 (D-26).
    /// 상태가 아직 nil 인 것(막 띄워 훅이 안 온 것)도 살아 있는 것으로 친다.
    var runningRepoIDs: Set<String> {
        Set(startedRepos.filter { state(forRepo: $0) != .dead })
    }

    func deletionImpact(of workspaceID: String) -> WorkspaceOps.Impact? {
        try? AppDatabase.queue.read { try WorkspaceOps.impact(of: workspaceID, in: $0) }
    }

    /// 확인창을 띄우기 **전에** 막을 이유가 있는지. nil 이면 지울 수 있다.
    func deletionRefusal(for workspaceID: String) -> WorkspaceOps.Refusal? {
        do {
            try AppDatabase.queue.read {
                try WorkspaceOps.checkDeletable(workspaceID, runningRepoIDs: runningRepoIDs, in: $0)
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
        let repoIDs = repos(in: workspaceID).map(\.id)
        try AppDatabase.queue.write {
            try WorkspaceOps.delete(workspaceID, runningRepoIDs: runningRepoIDs, in: $0)
        }
        // DB 가 지워진 **뒤에만** 폴더를 옮긴다. 순서가 반대면 DB 실패 시 문서만 사라진다 (D-26).
        do { try WorkspaceFolder.trash(workspaceID) }
        catch { NSLog("[Dure] 워크스페이스 폴더 휴지통 이동 실패: \(error)") }
        // 이미 죽은 페인들의 흔적. 층(D-27)도 이것으로 정리된다.
        for id in repoIDs {
            startedRepos.remove(id)
            sessionIDs[id] = nil
            promptByRepo[id] = nil
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
    func sessionID(for repo: Repo, kind: AgentKind = .claude) -> String {
        if let existing = sessionIDs[repo.id] { return existing }

        let uuid = UUID().uuidString
        sessionIDs[repo.id] = uuid
        let agent = Agent(dureSession: uuid,
                          repoId: repo.id,
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
        if reaction.ingestTranscript { ingestTranscripts(for: event.dureSession) }
        if reaction.refreshGit, let repo = repo(for: event.dureSession) { refreshGit(for: repo) }

        switch reaction.alert {
        case .waiting(let message):
            Notifier.post(title: WorkspaceSummary.alertTitle(
                              workspace: workspaceName(for: event.dureSession),
                              repo: repoName(for: event.dureSession),
                              suffix: "답을 기다립니다"),
                          body: message, dureSession: event.dureSession)
        case .done:
            Notifier.post(title: WorkspaceSummary.alertTitle(
                              workspace: workspaceName(for: event.dureSession),
                              repo: repoName(for: event.dureSession),
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
    func state(forRepo repoID: String) -> AgentState? {
        guard let session = sessionIDs[repoID] else { return nil }
        return agents.first { $0.dureSession == session }?.state
    }

    /// 그 페인을 실제로 띄운 CLI. agent 행에서 읽는다.
    private func agentKind(forRepo repoID: String) -> AgentKind? {
        guard let session = sessionIDs[repoID],
              let agent = agents.first(where: { $0.dureSession == session }) else { return nil }
        return AgentKind(rawValue: agent.agentKind)
    }

    func repoName(for dureSession: String) -> String {
        repo(for: dureSession)?.displayName ?? "에이전트"
    }

    /// 사이드바 워크스페이스 목록에 실을 숫자 (D-27).
    func summary(for workspaceID: String) -> WorkspaceSummary.Counts {
        let states = repos(in: workspaceID)
            .filter { startedRepos.contains($0.id) }
            .map { state(forRepo: $0.id) }
        return WorkspaceSummary.counts(states)
    }

    private func workspaceName(for dureSession: String) -> String? {
        guard let repo = repo(for: dureSession) else { return nil }
        return workspaces.first { $0.id == repo.workspaceId }?.name
    }

    private func repo(for dureSession: String) -> Repo? {
        guard let agent = agents.first(where: { $0.dureSession == dureSession }) else { return nil }
        return repos.first { $0.id == agent.repoId }
    }

    /// **`dead` 는 훅이 아니라 PTY 종료로 들어온다** (ADR-13 — 앱이 PTY 를 소유한다).
    /// `SessionEnd` 훅을 쓰지 않는 이유는 1차 훅 목록에 없고, 프로세스 종료가 더 확실해서다.
    func markDead(_ dureSession: String) {
        setState(.dead, for: dureSession, endedNow: true)
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

    // MARK: - F10a 실행 시점 브로드캐스트 (Step 7)

    /// **앱을 켜도 `claude` 는 저절로 뜨지 않는다.** 브리핑을 인자로 넘기려면
    /// 프로세스가 시작되기 *전에* 문구가 있어야 하기 때문이다 (설계문서 성공기준 3).
    func hasStarted(_ repoID: String) -> Bool { startedRepos.contains(repoID) }

    /// 그 페인이 출발할 때 받은 브리핑. 없으면 nil.
    func prompt(for repoID: String) -> String? { promptByRepo[repoID] }

    /// 페인 하나를 출발시킨다. 이미 떠 있으면 아무것도 하지 않는다 —
    /// 진행 중인 작업을 재시작으로 날리지 않기 위해서다.
    func start(_ repo: Repo) {
        guard !startedRepos.contains(repo.id) else { return }
        // 폴더가 없으면 띄워봐야 `cd` 에서 끝난다 (이슈 #10). 버튼을 잠그지만 여기서도 막는다.
        guard repo.folderExists else { return }
        let prompt = broadcastPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { promptByRepo[repo.id] = prompt }
        startedRepos.insert(repo.id)
        // agent 행을 여기서 만든다. workspace.md 의 "열려 있음 (X)" 는 이 행의 agentKind 를
        // 읽는다 (최종 리뷰 F4). 스폰보다 먼저이므로 훅 외래키 조건(ADR-17)도 그대로 지켜진다.
        _ = sessionID(for: repo)
        // "지금 페인이 열려 있음" 이 지도에 반영돼야 한다.
        refreshWorkspaceDoc()
    }

    /// F10a 의 본체 — 지금 보이는 페인 전부를 **같은 브리핑으로** 출발시킨다.
    func startAll() {
        for repo in visibleRepos { start(repo) }
    }

    /// 아직 안 뜬 페인이 하나라도 있는가. 버튼을 잠그는 데 쓴다.
    var hasUnstartedPanes: Bool {
        // 폴더 없는 레포는 셈에서 뺀다. 안 그러면 그것 하나 때문에 `전체 시작` 이 영영 켜져 있다.
        visibleRepos.contains { !startedRepos.contains($0.id) && $0.folderExists }
    }

    // MARK: - 워크스페이스 문서 (조율자 단계 1)

    /// 폴더를 만들고 `context.md` 를 읽어온다. 워크스페이스를 열 때 한 번.
    func openWorkspaceFolder() {
        guard let id = selectedWorkspaceID else { return }
        do { try WorkspaceFolder.ensure(id) }
        catch { NSLog("[Dure] 워크스페이스 폴더 준비 실패: \(error)") }
        // ensure 가 실패해도 읽는다. 안 읽으면 편집창에 **이전 워크스페이스의 글**이 남는다.
        loadContext(id)
        refreshWorkspaceDoc()
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

    /// `workspace.md` 를 다시 쓴다.
    ///
    /// **git 이 갱신될 때마다 함께 부른다.** 조율자가 읽는 지도가 낡으면
    /// "백엔드에 뭐가 바뀌었나" 를 틀리게 답한다.
    func refreshWorkspaceDoc() {
        guard let workspace = selectedWorkspace else { return }
        let lines = visibleRepos.map { repo in
            WorkspaceDoc.RepoLine(
                name: repo.displayName,
                path: repo.path,
                role: repo.role,
                git: git[repo.id],
                // 최종 리뷰 F4 — 워크스페이스 기본값이 아니라 **실제로 띄운** CLI 를 적는다.
                // 기본 CLI 를 codex 로 바꿔도 페인은 아직 claude 로만 뜬다. 지도가 거짓말을 하면
                // 조율자가 엉뚱한 CLI 를 가정한다.
                openedWith: startedRepos.contains(repo.id) ? agentKind(forRepo: repo.id) : nil
            )
        }
        let md = WorkspaceDoc.render(name: workspace.name, repos: lines)
        do { try WorkspaceFolder.writeMap(workspace.id, md) }
        catch { NSLog("[Dure] workspace.md 쓰기 실패: \(error)") }
    }

    // MARK: - F8 git 상태 (Step 7)

    /// 한 레포의 git 상태를 다시 읽는다.
    ///
    /// **메인액터에서 `git` 을 부르지 않는다.** MCP 가 많은 큰 레포는 `status` 가
    /// 수백 ms 걸릴 수 있고, 페인 수만큼 곱해지면 30초마다 UI 가 끊긴다.
    func refreshGit(for repo: Repo) {
        let (id, path) = (repo.id, repo.path)
        Task.detached(priority: .utility) {
            let fresh = GitReader.read(at: path)
            await MainActor.run {
                self.git.update(id, with: fresh)
                // 지도가 낡으면 조율자가 틀린 답을 한다.
                self.refreshWorkspaceDoc()
            }
        }
    }

    /// 지금 페인이 떠 있는 레포들만 읽는다.
    func refreshAllGit() {
        for repo in visibleRepos { refreshGit(for: repo) }
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
            refreshWorkspaceDoc()
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
