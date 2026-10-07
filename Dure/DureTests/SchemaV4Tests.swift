import Foundation
import GRDB
import Testing
@testable import Dure

/// 조율자 설계 단계 1 · 스키마 v4.
/// **이미 쓰던 DB 가 있는 상태에서 올라가는 것**을 확인한다. 새 DB 에서만 테스트하면
/// 기존 행에 기본값이 안 채워지는 실수를 못 잡는다.
struct SchemaV4Tests {

    @Test func 기존_워크스페이스에_claude_가_기본값으로_채워진다() throws {
        let q = try DatabaseQueue()
        // v3 까지만 올려 "이미 쓰던 사용자" 를 흉내낸다.
        try AppDatabase.migrator.migrate(q, upTo: "v3_usage")
        try q.write { db in
            try db.execute(sql: "INSERT INTO workspace (id, name) VALUES ('w1', '기존')")
        }

        try AppDatabase.migrator.migrate(q)

        let ws = try q.read { try Workspace.fetchOne($0, key: "w1") }
        #expect(ws?.defaultAgentKind == AgentKind.claude.rawValue)
    }

    @Test func 레포_역할은_비어_있어도_된다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo",
                     label: nil, model: nil, role: nil).insert(db)
        }
        #expect(try q.read { try Repo.fetchOne($0, key: "r1") }?.role == nil)
    }

    @Test func 역할을_적으면_그대로_읽힌다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws", defaultAgentKind: "codex").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo",
                     label: nil, model: nil, role: "API 서버").insert(db)
        }
        #expect(try q.read { try Repo.fetchOne($0, key: "r1") }?.role == "API 서버")
        #expect(try q.read { try Workspace.fetchOne($0, key: "w1") }?.defaultAgentKind == "codex")
    }
}
