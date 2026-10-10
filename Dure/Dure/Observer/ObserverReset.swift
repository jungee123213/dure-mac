// Dure/Dure/Observer/ObserverReset.swift
import Foundation
import GRDB

/// 감시자 데이터 재구성 — 표를 비우고 jsonl 에서 다시 모은다.
/// 수집 규칙(세대 나누기 · 서브에이전트 귀속 등)이 고쳐졌을 때, 이미 쌓인 옛 규칙의 결과를 한 번에 바로잡는 길이다.
nonisolated enum ObserverReset {

    enum Outcome: Equatable, Sendable {
        case done
        case refusedRunning
    }

    /// 자식부터. 외래키가 cascade 라 부모만 지워도 되지만 순서를 지켜 두면 cascade 설정이 바뀌어도 안전하다.
    /// **`observer_session` 은 남긴다** — 지난 평가 · 묻기 세션이 다시 수집되어 작업으로 잡히면 안 된다.
    static let tables = ["finding", "backlog_item", "evaluation_run", "obs_permission",
                         "obs_tool", "obs_usage", "obs_turn", "work_unit", "obs_cursor"]

    static func wipe(in db: Database) throws {
        for t in tables { try db.execute(sql: "DELETE FROM \(t)") }
    }

    static func hasRunning(in db: Database) throws -> Bool {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM evaluation_run WHERE status = 'running'") ?? 0) > 0
    }

    /// 수집 잠금 안에서: 실행 중 평가 확인 → 한 트랜잭션으로 비우기 → 실행 폴더 지우기(`reference/` 는 남김).
    /// 확인과 비우기가 한 트랜잭션이라 그 사이에 평가가 시작되어 지워지는 일이 없다.
    static func run(db: DatabaseQueue, dirs: ObserverDirs) throws -> Outcome {
        try ObsCollector.exclusively {
            let refused = try db.write { db -> Bool in
                if try hasRunning(in: db) { return true }
                try wipe(in: db)
                return false
            }
            if refused { return .refusedRunning }
            let fm = FileManager.default
            // DB 는 이미 커밋됐다 — 폴더를 못 지웠다고 재구성 전체를 실패로 알리지 않는다(남은 폴더는 무해한 찌꺼기).
            if fm.fileExists(atPath: dirs.units.path) {
                do { try fm.removeItem(at: dirs.units) } catch { NSLog("[Dure] 감시자 units 폴더 삭제 실패: \(error)") }
            }
            return .done
        }
    }
}
