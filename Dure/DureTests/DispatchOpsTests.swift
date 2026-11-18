import Foundation
import GRDB
import Testing
@testable import Dure

/// 단계 4 · 스키마 v6. 배분 기록은 **대시보드 이력이자 큐 그 자체**다 — `state = queued` 행이 곧 큐.
struct DispatchOpsTests {

    static func db() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "모바일").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/a/android").insert(db)
            try Repo(id: "r2", workspaceId: "w1", path: "/a/ios").insert(db)
        }
        return q
    }

    static func newIssueReq() -> DispatchGitRequest {
        DispatchGitRequest(mode: .newIssue, issueTitle: "제목", issueBody: "본문", branchHint: "login", baseBranch: "feat/#9/base", scope: .commit)
    }

    @Test func 새_이슈_배분은_초안과_범위를_남긴다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", git: Self.newIssueReq(), toolUseId: nil, now: 10, in: $0) }
        let got = try q.read { try Dispatch.fetchOne($0, key: d.id) }
        #expect(got?.gitMode == .newIssue)
        #expect(got?.issueTitle == "제목" && got?.issueBody == "본문" && got?.branchHint == "login")
        #expect(got?.baseBranch == "feat/#9/base")
        #expect(got?.gitScope == .commit)
        #expect(got?.issueNumber == nil)
    }

    static func continueRow(_ q: DatabaseQueue) throws -> Dispatch {
        let req = DispatchGitRequest(mode: .continueWork, branch: "feat/#165/x", issueNumber: 165, scope: .pr)
        return try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", git: req, toolUseId: nil, now: 10, in: $0) }
    }

    @Test func 이어_하기는_이슈와_브랜치를_바로_남긴다() throws {
        let q = try Self.db()
        let d = try Self.continueRow(q)
        let got = try q.read { try Dispatch.fetchOne($0, key: d.id) }
        #expect(got?.gitMode == .continueWork && got?.issueNumber == 165 && got?.branch == "feat/#165/x")
    }

    @Test func 완료는_보고된_값만_덮는다() throws {
        let q = try Self.db()
        let d = try Self.continueRow(q)
        try q.write { try DispatchOps.markDone(d.id, result: "끝", completion: .init(issueNumber: nil, branch: "b", prNumber: 42), now: 20, in: $0) }
        let got = try q.read { try Dispatch.fetchOne($0, key: d.id) }
        #expect(got?.issueNumber == 165 && got?.branch == "b" && got?.prNumber == 42 && got?.state == .done)
    }

    @Test func 번호는_워크스페이스_안에서_1부터_오른다() throws {
        let q = try Self.db()
        let (a, b) = try q.write { db in
            (try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "하나", toolUseId: nil, now: 10, in: db),
             try DispatchOps.enqueue(workspaceID: "w1", repoID: "r2", title: "둘", instruction: "둘", toolUseId: "tu", now: 11, in: db))
        }
        #expect(a.seq == 1 && b.seq == 2)
        #expect(a.state == .queued && b.title == "둘" && b.toolUseId == "tu")
    }

    @Test func 큐는_레포별_선입선출이다() throws {
        let q = try Self.db()
        try q.write { db in
            _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "첫째", toolUseId: nil, now: 10, in: db)
            _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r2", title: nil, instruction: "남의 것", toolUseId: nil, now: 11, in: db)
            _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "둘째", toolUseId: nil, now: 12, in: db)
        }
        let queued = try q.read { try DispatchOps.queued(repoID: "r1", in: $0) }
        #expect(queued.map(\.instruction) == ["첫째", "둘째"])
    }

    @Test func 전달_완료_실패가_시각과_함께_남는다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        try q.write { try DispatchOps.markDelivered(d.id, session: "cc-1", now: 20, in: $0) }
        let delivered = try q.read { try DispatchOps.outstanding(repoID: "r1", in: $0) }
        #expect(delivered?.id == d.id && delivered?.deliveredAt == 20 && delivered?.deliveredSession == "cc-1")
        try q.write { try DispatchOps.markDone(d.id, result: "끝", now: 30, in: $0) }
        let done = try q.read { try Dispatch.fetchOne($0, key: d.id) }
        #expect(done?.state == .done && done?.result == "끝" && done?.doneAt == 30)
        #expect(try q.read { try DispatchOps.outstanding(repoID: "r1", in: $0) } == nil)
    }

    /// 이슈 #24 — 응답 대기도 그 페인이 하고 있는 일이다.
    @Test func 응답_대기도_열린_배분이다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        try q.write { try DispatchOps.markDelivered(d.id, session: "cc-1", now: 20, in: $0) }
        try q.write { try DispatchOps.markWaiting(d.id, lastMessage: "질문", in: $0) }
        let open = try q.read { try DispatchOps.outstanding(repoID: "r1", in: $0) }
        #expect(open?.state == .waiting && open?.result == "질문")
        try q.write { try DispatchOps.adoptSession(d.id, session: "cc-2", in: $0) }
        #expect(try q.read { try Dispatch.fetchOne($0, key: d.id) }?.deliveredSession == "cc-2")
        let closed = try q.write { try DispatchOps.failUndelivered(reason: "앱 종료", now: 99, in: $0) }
        #expect(closed.map(\.id) == [d.id])
    }

    @Test func 취소는_큐에_있는_것만() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        #expect(try q.write { try DispatchOps.cancel(d.id, in: $0) } == true)
        #expect(try q.write { try DispatchOps.cancel(d.id, in: $0) } == false)   // 이미 cancelled
        #expect(try q.read { try DispatchOps.queued(repoID: "r1", in: $0) }.isEmpty)
    }

    /// Review Focus 3 — 앱이 꺼진 사이 `delivered` 로 남은 것은 Stop 을 영영 못 본다.
    @Test func 앱_시작_때_열린_배분을_실패로_닫는다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        try q.write { try DispatchOps.markDelivered(d.id, session: "cc", now: 11, in: $0) }
        let closed = try q.write { try DispatchOps.failUndelivered(reason: "앱 종료", now: 99, in: $0) }
        #expect(closed.map(\.id) == [d.id])
        let row = try q.read { try Dispatch.fetchOne($0, key: d.id) }
        #expect(row?.state == .failed && row?.failure == "앱 종료" && row?.doneAt == 99)
    }

    @Test func 시도_횟수를_센다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        let n = try q.write { try DispatchOps.bumpAttempts(d.id, in: $0) }
        #expect(n == 1)
        #expect(try q.write { try DispatchOps.bumpAttempts(d.id, in: $0) } == 2)
    }

    @Test func 조율자행_메시지는_워크스페이스별_큐다() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        try q.write { db in
            _ = try DispatchOps.enqueueRelay(workspaceID: "w1", dispatchID: d.id, repoID: "r1", kind: .completion, body: "끝", now: 20, in: db)
            _ = try DispatchOps.enqueueRelay(workspaceID: "w1", dispatchID: nil, repoID: "r2", kind: .question, body: "왜?", now: 21, in: db)
        }
        let queued = try q.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }
        #expect(queued.map(\.kind) == [.completion, .question])
        try q.write { try DispatchOps.markRelaysDelivered(queued.map(\.id), now: 30, in: $0) }
        #expect(try q.read { try DispatchOps.queuedRelays(workspaceID: "w1", in: $0) }.isEmpty)
    }

    @Test func 이력은_최신이_먼저다() throws {
        let q = try Self.db()
        try q.write { db in
            _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "옛", toolUseId: nil, now: 10, in: db)
            _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "새", toolUseId: nil, now: 20, in: db)
        }
        #expect(try q.read { try DispatchOps.history(workspaceID: "w1", in: $0) }.map(\.instruction) == ["새", "옛"])
    }

    /// 워크스페이스를 지우면 배분 기록도 함께 간다(D-26 연쇄). 레포를 지우면 그 레포 배분도.
    @Test func 연쇄_삭제() throws {
        let q = try Self.db()
        let d = try q.write { try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        try q.write { _ = try DispatchOps.enqueueRelay(workspaceID: "w1", dispatchID: d.id, repoID: "r1", kind: .completion, body: "b", now: 1, in: $0) }
        try q.write { _ = try Repo.deleteOne($0, key: "r1") }
        try q.read { db in
            #expect(try Dispatch.fetchCount(db) == 0)
            // relay 는 남되 가리키던 것이 비워진다
            let r = try Relay.fetchOne(db)
            #expect(r?.dispatchId == nil && r?.repoId == nil)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        try q.write { _ = try Workspace.deleteOne($0, key: "w1") }
        #expect(try q.read { try Relay.fetchCount($0) } == 0)
    }

    @Test func 삭제_영향에_배분_수가_들어간다() throws {
        let q = try Self.db()
        try q.write { _ = try DispatchOps.enqueue(workspaceID: "w1", repoID: "r1", title: nil, instruction: "x", toolUseId: nil, now: 10, in: $0) }
        #expect(try q.read { try WorkspaceOps.impact(of: "w1", in: $0) } == .init(repos: 2, sessions: 0, dispatches: 1))
    }
}
