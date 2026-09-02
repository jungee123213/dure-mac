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
    /// ADR-17 의 매핑 결과. Step 5(F6·F7) 가 여기 `transcriptPath` 를 직접 읽는다.
    private(set) var ccSessions: [CCSession] = []
    /// 페인별 토큰 합계. `/clear` 로 갈라진 cc_session 들을 **합산한다** (부록 A4 주석).
    private(set) var usageByAgent: [String: UsageTotals] = [:]
    var selectedWorkspaceID: String?

    /// 페인 하나당 UUID 하나 (ADR-14 의 `DURE_SESSION`).
    /// 뷰가 다시 그려져도 같은 값이어야 훅이 보내는 값과 앱의 매핑이 어긋나지 않는다.
    /// **뷰 갱신을 유발하면 안 되므로** 관측 대상에서 뺀다.
    @ObservationIgnored private var sessionIDs: [String: String] = [:]

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// 현재 워크스페이스의 레포들. 터미널 페인은 이 순서대로 세로로 쌓인다 (ADR-13).
    var visibleRepos: [Repo] {
        guard let id = selectedWorkspaceID else { return [] }
        return repos.filter { $0.workspaceId == id }
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
    func addWorkspace(name: String) -> Workspace? {
        let w = Workspace(name: name)
        do {
            try AppDatabase.queue.write { try w.insert($0) }
            load()
            selectedWorkspaceID = w.id
            return w
        } catch {
            NSLog("[Dure] addWorkspace 실패: \(error)")
            return nil
        }
    }

    func addRepo(path: String, to workspaceID: String) {
        let r = Repo(workspaceId: workspaceID, path: path, label: nil, model: nil)
        do {
            try AppDatabase.queue.write { try r.insert($0) }
            load()
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
                          // 전이는 Step 6(F4). 여기서는 넣기만 한다.
                          state: "started",
                          model: repo.model,
                          startedAt: Int(Date().timeIntervalSince1970),
                          endedAt: nil)
        do { try AppDatabase.queue.write { try agent.insert($0) } }
        catch { NSLog("[Dure] agent 등록 실패: \(error)") }
        return uuid
    }

    /// 훅 이벤트 하나를 반영한다. 부록 A2.
    func apply(_ event: HookEvent) {
        switch event.ev {
        case "SessionStart":
            bridgeSession(event)
        case "Stop":
            // 응답이 끝났다 = 트랜스크립트에 usage 가 다 적혔다. **이때가 읽을 때다.**
            // 파일 감시자를 세션마다 다는 것보다 싸고, 훅이 이미 알려주는 것을 또 볼 이유가 없다 (ADR-3).
            ingestTranscripts(for: event.dureSession)
        default:
            // UserPromptSubmit · Notification 은 상태·알림용이라 Step 6 에서 쓴다.
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

    func setModel(_ model: String?, for repo: Repo) {
        var r = repo
        r.model = model
        do {
            try AppDatabase.queue.write { try r.update($0) }
            load()
        } catch {
            NSLog("[Dure] setModel 실패: \(error)")
        }
    }
}
