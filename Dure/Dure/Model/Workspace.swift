import Foundation
import GRDB

struct Workspace: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var name: String
    /// 이 워크스페이스에서 페인을 열 때의 기본 CLI (설계문서 8절).
    /// 페인마다 시작 화면에서 바꿀 수 있으므로 여기 값은 "미리 골라둔 것" 일 뿐이다.
    var defaultAgentKind: String = AgentKind.claude.rawValue

    static let databaseTableName = "workspace"

    enum CodingKeys: String, CodingKey {
        case id, name
        case defaultAgentKind = "default_agent_kind"
    }
}

struct Repo: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String = UUID().uuidString
    var workspaceId: String
    var path: String
    var label: String?
    /// 예전에 `claude --model` 로 넘기던 값. **이제 쓰지 않는다** — 모델은 사람이 터미널에서
    /// `/model` 이나 레포 설정으로 고른다. 기존 DB 컬럼이 있어 마이그레이션 없이 자리만 남겨둔다.
    var model: String?
    /// 조율자가 읽는 한 줄 설명("API 서버", "안드로이드 클라이언트").
    /// `workspace.md` 에 실린다 (설계문서 4절).
    var role: String?

    static let databaseTableName = "repo"

    enum CodingKeys: String, CodingKey {
        case id, path, label, model, role
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
