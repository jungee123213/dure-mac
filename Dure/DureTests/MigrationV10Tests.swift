import Foundation
import GRDB
import Testing
@testable import Dure

struct MigrationV10Tests {

    @Test func createsRateLimitTable() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v9_answer")
        let before = try q.read { try $0.tableExists("rate_limit") }
        #expect(!before)
        try AppDatabase.migrator.migrate(q)
        let columns = try q.read { db in try db.columns(in: "rate_limit").map(\.name) }
        #expect(Set(columns) == ["kind", "window", "used_percent", "window_minutes", "resets_at",
                                 "plan_type", "reached_type", "seen_at"])
        try q.write { db in
            try RateLimitWindow(kind: "codex", window: "primary", usedPercent: 10, windowMinutes: 300,
                                resetsAt: 1, planType: "plus", reachedType: nil, seenAt: 5).insert(db)
            try RateLimitWindow(kind: "codex", window: "primary", usedPercent: 42, windowMinutes: 300,
                                resetsAt: 2, planType: "plus", reachedType: nil, seenAt: 6).insert(db)
        }
        let rows = try q.read { try RateLimitWindow.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows.first?.usedPercent == 42)
    }
}
