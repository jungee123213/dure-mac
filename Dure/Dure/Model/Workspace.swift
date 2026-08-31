import Foundation
import GRDB

struct Workspace: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var name: String

    static let databaseTableName = "workspace"
}

struct Repo: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var workspaceId: String
    var path: String
    var label: String?
    /// `claude --model` 에 넘길 별칭. nil 이면 기본 모델.
    var model: String?

    static let databaseTableName = "repo"

    enum CodingKeys: String, CodingKey {
        case id, path, label, model
        case workspaceId = "workspace_id"
    }

    /// 표시용 이름. label 이 없으면 폴더명을 쓴다.
    var displayName: String {
        label ?? (path as NSString).lastPathComponent
    }
}
