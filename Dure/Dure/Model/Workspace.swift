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

    /// 등록 뒤에 폴더가 옮겨지거나 지워질 수 있다. 없는 폴더로 스폰하면 `cd` 가 실패하므로
    /// 시작 전에 사람에게 보여주고 막는 근거로 쓴다 (이슈 #10). 같은 이름의 파일도 `cd` 가 실패하므로 없는 것으로 친다.
    var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 표시용 이름. label 이 없으면 폴더명을 쓴다.
    var displayName: String {
        label ?? (path as NSString).lastPathComponent
    }
}
