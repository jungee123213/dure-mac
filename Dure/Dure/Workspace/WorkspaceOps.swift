import Foundation
import GRDB

/// 이슈 #12 — 워크스페이스 만들기·이름 바꾸기·삭제의 DB 쪽.
///
/// `SessionBridge` 처럼 `Database` 를 인자로 받는다 — 메모리 DB 로 테스트하기 위해서다.
/// **폴더(휴지통 이동)는 여기서 하지 않는다.** DB 가 실패했는데 폴더만 사라지면 안 되므로
/// 스토어가 DB 성공 뒤에 따로 부른다 (D-26).
enum WorkspaceOps {

    enum Refusal: Error, Equatable {
        case emptyName
        /// 0개일 때의 빈 화면을 따로 두지 않는다 (D-26).
        case lastWorkspace
        /// 돌던 claude 의 agent 행이 연쇄로 지워지면 훅 이벤트가 갈 곳을 잃는다.
        case hasRunningPanes

        var message: String {
            switch self {
            case .emptyName: "이름을 입력하세요."
            case .lastWorkspace: "마지막 워크스페이스는 삭제할 수 없습니다. 새 워크스페이스를 먼저 만드세요."
            case .hasRunningPanes: "실행 중인 터미널이 있습니다. 모두 종료한 뒤 삭제하세요."
            }
        }
    }

    /// 삭제 확인창에 "무엇이 사라지는지" 를 보여주기 위한 숫자.
    struct Impact: Equatable {
        var repos: Int
        /// 에이전트 기록 수. 토큰·툴 사용량이 여기 딸려 있다.
        var sessions: Int
    }

    static func create(name: String, defaultAgentKind: AgentKind = .claude,
                       in db: Database) throws -> Workspace {
        let w = Workspace(name: try validName(name), defaultAgentKind: defaultAgentKind.rawValue)
        try w.insert(db)
        return w
    }

    static func rename(_ workspaceID: String, to name: String, in db: Database) throws {
        let trimmed = try validName(name)
        guard var w = try Workspace.fetchOne(db, key: workspaceID) else { return }
        w.name = trimmed
        try w.update(db)
    }

    static func impact(of workspaceID: String, in db: Database) throws -> Impact {
        let repos = try repoIDs(in: workspaceID, db)
        let sessions = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM agent
            WHERE repo_id IN (SELECT id FROM repo WHERE workspace_id = ?)
            """, arguments: [workspaceID]) ?? 0
        return Impact(repos: repos.count, sessions: sessions)
    }

    /// 지울 수 있는지만 본다. 확인창을 띄우기 **전에** 막기 위해 따로 둔다.
    /// - Parameter runningRepoIDs: 지금 claude 가 살아 있는 레포. 앱 메모리에만 있는 값이라 인자로 받는다.
    static func checkDeletable(_ workspaceID: String, runningRepoIDs: Set<String>,
                               in db: Database) throws {
        guard try Workspace.fetchCount(db) > 1 else { throw Refusal.lastWorkspace }
        guard runningRepoIDs.isDisjoint(with: try repoIDs(in: workspaceID, db)) else {
            throw Refusal.hasRunningPanes
        }
    }

    static func delete(_ workspaceID: String, runningRepoIDs: Set<String>,
                       in db: Database) throws {
        try checkDeletable(workspaceID, runningRepoIDs: runningRepoIDs, in: db)
        // repo → agent → cc_session → token_usage · tool_use 가 연쇄로 지워진다 (v1~v3 외래키).
        // 레포 폴더와 코드는 건드리지 않는다 — Dure 의 등록 정보만 지운다.
        _ = try Workspace.deleteOne(db, key: workspaceID)
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Refusal.emptyName }
        return trimmed
    }

    private static func repoIDs(in workspaceID: String, _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM repo WHERE workspace_id = ?",
                            arguments: [workspaceID])
    }
}
