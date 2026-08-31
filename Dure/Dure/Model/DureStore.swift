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
    var selectedWorkspaceID: String?

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
