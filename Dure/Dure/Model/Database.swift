import Foundation
import GRDB

/// 부록 A4 스키마의 1차분(workspace · repo)만 만든다.
/// agent · cc_session · read_cursor 는 Step 4·5 에서 마이그레이션으로 얹는다.
enum AppDatabase {

    /// 부록 A5 — GRDB 는 `DatabaseQueue` 하나로 직렬화한다.
    static let queue: DatabaseQueue = {
        do { return try makeQueue() }
        catch { fatalError("DB 초기화 실패: \(error)") }
    }()

    static func makeQueue() throws -> DatabaseQueue {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory,
                             in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Dure", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let q = try DatabaseQueue(path: dir.appendingPathComponent("dure.sqlite").path)
        try migrator.migrate(q)
        return q
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_workspace_repo") { db in
            try db.create(table: "workspace") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
            }
            try db.create(table: "repo") { t in
                t.primaryKey("id", .text)
                t.column("workspace_id", .text).notNull()
                    .references("workspace", onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("label", .text)
                // v5 — 터미널별 모델. claude --model 에 그대로 넘긴다. NULL 이면 기본값.
                t.column("model", .text)
            }
        }
        return m
    }
}
