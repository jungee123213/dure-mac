// Dure/DureTests/EvaluationJobTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct EvaluationJobTests {

    let db: DatabaseQueue
    let dirs: ObserverDirs
    let repoDir: URL

    init() throws {
        db = try Fx.memoryDB()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("evaljob-\(UUID().uuidString)")
        repoDir = tmp.appendingPathComponent("moamap-iOS")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try "# iOS".write(to: repoDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        dirs = ObserverDirs(root: tmp.appendingPathComponent("observer"), claudeHome: tmp.appendingPathComponent("claude"),
                            workspacesRoot: tmp.appendingPathComponent("workspaces"), settingsDir: tmp.appendingPathComponent("settings"))
        for d in [dirs.reference, dirs.claudeHome.appendingPathComponent("skills")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "- **확인일:** 2026-10-10 · **재검토 기한:** 2027-01-10\n".write(
            to: dirs.reference.appendingPathComponent("practices.md"), atomically: true, encoding: .utf8)
        let root = repoDir.path
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path, label) VALUES ('r1', 'w1', ?, 'iOS');
                INSERT INTO dispatch (id, workspace_id, seq, repo_id, instruction, state, created_at, delivered_at, done_at, result)
                    VALUES ('d1', 'w1', 7, 'r1', '스플래시를 안드로이드와 같게', 'done', 1000, 1100, 1500, '옮겼습니다');
                """, arguments: [root])
            try WorkUnit(id: "u1", unitKey: "k", baseKey: "k", kind: .issueBranch, repoRoot: root, branch: "feat/#52/x",
                         issueNo: 52, githubRepo: "Moa-Map/moamap-iOS", workspaceId: "w1", firstTs: 1000, lastTs: 2000,
                         humanTurns: 3, sourceRevision: 5).insert(db)
            try ObsTurn(id: "t1", unitId: "u1", eventId: "e1a2b3c4-aaaa", ccSessionId: "sess-aaaa-1", transcriptPath: "/gone/a.jsonl",
                        lineNo: 1, origin: .terminal, promptKind: .human, ts: 1200, prompt: "안드로이드 #288 을 iOS 로 옮겨줘").insert(db)
            try ObsTool(turnId: "t1", transcriptPath: "/gone/a.jsonl", toolUseId: "x", name: "Read",
                        target: "\(root)/A.swift", startedTs: 1201, resultTs: 1202).insert(db)
            try WorkUnit(id: "o1", unitKey: "o", baseKey: "o", kind: .orchestrator, cwd: "/ws/w1", day: "2026-10-10",
                         workspaceId: "w1", firstTs: 900, lastTs: 900).insert(db)
            try ObsTurn(id: "ot", unitId: "o1", eventId: "orch-0001", ccSessionId: "orch", transcriptPath: "/o.jsonl", lineNo: 1,
                        origin: .dureOrchestrator, promptKind: .human, ts: 950, prompt: "iOS 에 스플래시 옮겨").insert(db)
            try BacklogItem(key: "sibling-repo-read", bucket: .dure, grp: "dure", kind: "friction", title: "형제 레포 읽기",
                            detail: "iOS 페인이 안드로이드를 못 읽는다", state: .open).insert(db)
        }
    }

    static let goodStructured: [String: Any] = [
        "summary": "포팅은 잘 됐다",
        "findings": [
            ["group": "dure", "kind": "friction", "key": "sibling-repo-read", "title": "iOS 페인이 안드로이드를 못 읽음",
             "detail": "d", "evidence": [["event": "e1a2b3c4", "quote": "#288 을 iOS 로"]], "severity": 3, "confidence": "high"],
            ["group": "habit", "kind": "prompt", "key": "made-up", "title": "지어낸 지적", "detail": "d",
             "evidence": [["event": "deadbeef", "quote": "없는 말 없는 말"]], "severity": 1, "confidence": "low"],
        ],
    ]

    func env(_ runner: FakeRunner, flush: @escaping @Sendable () -> Void = {}) -> EvalEnvironment {
        EvalEnvironment(db: db, runner: runner, dirs: dirs, timeZone: TimeZone(identifier: "UTC")!, now: { 5000 },
                        newSessionID: { "eval-session-1" }, flush: flush)
    }

    static func runner(_ stream: String = Fx.claudeStream(EvaluationJobTests.goodStructured, cost: 0.31)) -> FakeRunner {
        FakeRunner { script in
            if script.contains("claude -p") { return FakeRunner.ok(stream) }
            if script.contains("diff --shortstat") { return FakeRunner.ok("__DURE_OUT__\n 2 files changed, 5 insertions(+)\n") }
            return FakeRunner.ok("")
        }
    }

    func queue(_ trigger: RunTrigger = .manual) throws -> EvaluationRun {
        try #require(try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: trigger, now: 4000, in: $0) })
    }

    @Test func 성공하면_실행이_완료되고_검증된_지적만_남는다() async throws {
        let run = try queue()
        let out = await EvaluationJob.run(runID: run.id, env: env(Self.runner()))
        #expect(out == .evaluated(.init(new: 0, reopened: 0, repeated: 1), rejected: 1))
        let r = try await db.read { try #require(try EvaluationRun.fetchOne($0, key: run.id)) }
        #expect(r.status == .done && r.finishedAt == 5000 && r.costUsd == 0.31 && r.summary == "포팅은 잘 됐다")
        #expect(r.sourceRevision == 5 && r.accepted == 1 && r.rejected == 1)
        #expect(r.sessionId == "eval-session-1" && r.promptVersion == EvalSpec.promptVersion && r.referenceStamp == "2027-01-10")
        let dir = dirs.runDir(unit: "u1", run: run.id)
        for f in ["digest.md", "backlog.md", "prompt.md", "report.md"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), "\(f)")
        }
        let report = try String(contentsOf: dir.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("iOS 페인이 안드로이드를 못 읽음") && !report.contains("지어낸 지적"))
        #expect(report.contains("검증에서 버린 지적 1개"))
        #expect(try await db.read { try BacklogItem.fetchOne($0, key: "made-up") } == nil)
        #expect(try await db.read { try BacklogItem.fetchOne($0, key: "sibling-repo-read") }?.observedCount == 1)
        // 평가 세션은 수집에서 빠지도록 먼저 기록된다
        #expect(try await db.read { try ObserverSession.fetchOne($0, key: "eval-session-1") }?.kind == "eval")
        #expect(try await db.read { try WorkUnit.fetchOne($0, key: "u1") }?.linesChanged == 5)
    }

    /// 시나리오 3 — flush 로 들어온 새 턴까지 스냅숏에 포함되고, 그 뒤 변경은 "평가 뒤 변경" 으로 보인다.
    @Test func 스냅숏은_flush_뒤의_revision() async throws {
        let run = try queue()
        let db = db
        _ = await EvaluationJob.run(runID: run.id, env: env(Self.runner(), flush: {
            try? db.write { try $0.execute(sql: "UPDATE work_unit SET source_revision = 6 WHERE id = 'u1'") }
        }))
        let r = try await db.read { try #require(try EvaluationRun.fetchOne($0, key: run.id)) }
        #expect(r.sourceRevision == 6)
        try await db.write { try $0.execute(sql: "UPDATE work_unit SET source_revision = 7 WHERE id = 'u1'") }
        let u = try await db.read { try #require(try WorkUnit.fetchOne($0, key: "u1")) }
        #expect(ObserverRules.isStale(unit: u, run: r))
    }

    @Test func 다이제스트에_배분_조율자_diff_참조() async throws {
        let run = try queue()
        _ = await EvaluationJob.run(runID: run.id, env: env(Self.runner()))
        let digest = try String(contentsOf: dirs.runDir(unit: "u1", run: run.id).appendingPathComponent("digest.md"), encoding: .utf8)
        #expect(digest.contains("배분 #7 → iOS · done · 큐 대기 100초"))
        #expect(digest.contains("iOS 에 스플래시 옮겨"))
        #expect(digest.contains("2 files changed, 5 insertions(+)"))
        #expect(digest.contains("\(repoDir.path)/CLAUDE.md"))
        #expect(digest.contains("/gone/a.jsonl (원본 삭제됨)"))
        let backlog = try String(contentsOf: dirs.runDir(unit: "u1", run: run.id).appendingPathComponent("backlog.md"), encoding: .utf8)
        #expect(backlog.contains("`sibling-repo-read`"))
    }

    @Test func 평가_명령은_격리되고_있는_폴더만_붙인다() async throws {
        let r = Self.runner()
        let run = try queue()
        _ = await EvaluationJob.run(runID: run.id, env: env(r))
        let s = r.scripts.first { $0.contains("claude -p") } ?? ""
        #expect(s.contains("--safe-mode") && s.contains("--strict-mcp-config") && s.contains("--session-id 'eval-session-1'"))
        #expect(s.contains("--add-dir '\(repoDir.path)'") && s.contains("--add-dir '\(dirs.reference.path)'"))
        #expect(s.contains("--add-dir '\(dirs.claudeHome.path)/skills'"))
        #expect(!s.contains("/gone"))
    }

    /// Review Focus 1.
    @Test func 격리_실패면_기록하지_않는다() async throws {
        let run = try queue()
        let out = await EvaluationJob.run(runID: run.id, env: env(Self.runner(Fx.claudeStream(Self.goodStructured, tools: ["Read", "Bash"]))))
        guard case .failed(let m) = out else { Issue.record("실패가 아님"); return }
        #expect(m.contains("격리 실패"))
        #expect(try await db.read { try EvaluationRun.fetchOne($0, key: run.id) }?.status == .failed)
        #expect(try await db.read { try Finding.fetchCount($0) } == 0)
    }

    @Test func 종료_코드가_0_이_아니면_실패() async throws {
        let run = try queue()
        let r = FakeRunner { _ in CommandResult(status: 127, stdout: Data(), stderr: Data("command not found: claude".utf8), timedOut: false) }
        guard case .failed(let m) = await EvaluationJob.run(runID: run.id, env: env(r)) else { Issue.record(""); return }
        #expect(m.contains("command not found"))
        let saved = try await db.read { try #require(try EvaluationRun.fetchOne($0, key: run.id)) }
        #expect(saved.status == .failed && saved.failure?.contains("command not found") == true && saved.finishedAt == 5000)
    }

    @Test func 큐에_없던_실행은_건너뛴다() async throws {
        let run = try queue()
        try await db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'cancelled'") }
        #expect(await EvaluationJob.run(runID: run.id, env: env(Self.runner())) == .skipped)
    }

    @Test func 같은_단위에_대기_실행은_하나뿐() throws {
        _ = try queue()
        #expect(try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .auto, now: 1, in: $0) } == nil)
    }

    /// 리뷰 재현 — 자동 실행이 보류(자동 평가 꺼짐)된 채 queued 일 때 수동 요청이 거절되면 평가할 방법이 없다.
    @Test func manualEvaluationCanOverridePausedAutoQueue() throws {
        let auto = try queue(.auto)
        let promoted = try #require(try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .manual, now: 5000, in: $0) })
        #expect(promoted.id == auto.id && promoted.trigger == .manual)
        #expect(try db.read { try EvaluationRun.fetchCount($0) } == 1)
        var s = ObserverSettings()
        s.autoEvaluate = false
        let queued = try db.read { try EvaluationRun.fetchAll($0) }
        #expect(ObserverRules.next(queued: queued, autoRunsToday: 0, s)?.id == auto.id)
    }

    @Test func 실행_중이면_수동_요청은_거절된다() throws {
        let run = try queue(.auto)
        try db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'running' WHERE id = ?", arguments: [run.id]) }
        #expect(try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .manual, now: 5000, in: $0) } == nil)
        #expect(try db.read { try EvaluationRun.fetchOne($0) }?.trigger == .auto)
    }

    @Test func 수동_대기가_있으면_다시_수동_요청은_중복으로_거절() throws {
        _ = try queue(.manual)
        #expect(try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .manual, now: 5000, in: $0) } == nil)
        #expect(try db.read { try EvaluationRun.fetchCount($0) } == 1)
    }

    // MARK: - 늦게 자격이 생긴 머지 단위

    func markMerged(_ at: Int) throws {
        try db.write { try $0.execute(sql: "UPDATE work_unit SET merged_at = ? WHERE id = 'u1'", arguments: [at]) }
    }

    @Test func 늦게_자격이_생긴_머지_단위는_다음_수집_뒤_자동으로_들어간다() throws {
        try markMerged(3000)
        let n = try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, ObserverSettings(), now: 6000, in: $0) }
        #expect(n == 1)
        let r = try db.read { try EvaluationRun.fetchAll($0) }
        #expect(r.count == 1 && r[0].trigger == .auto && r[0].status == .queued)
        // 멱등 — 이미 대기 중이다
        #expect(try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, ObserverSettings(), now: 6001, in: $0) } == 0)
    }

    @Test func 자동_실행_이력이_있으면_다시_넣지_않는다() throws {
        try markMerged(3000)
        let run = try queue(.auto)
        try db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'failed' WHERE id = ?", arguments: [run.id]) }
        #expect(try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, ObserverSettings(), now: 6000, in: $0) } == 0)
        #expect(try db.read { try EvaluationRun.fetchCount($0) } == 1)
    }

    /// 수동으로 승격된 실행은 trigger 가 manual 이 되지만 자동 몫은 이미 치른 것이다 — 끝난 뒤 한 번 더 자동으로 돌지 않게.
    @Test func 승격된_실행이_끝나도_자동을_다시_넣지_않는다() throws {
        try markMerged(3000)
        _ = try queue(.auto)
        _ = try db.write { try EvaluationJob.enqueue(unitID: "u1", trigger: .manual, now: 5000, in: $0) }
        try db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'done'") }
        #expect(try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, ObserverSettings(), now: 6000, in: $0) } == 0)
    }

    @Test func 첫_시작_전_머지는_넣지_않는다() throws {
        try markMerged(500)
        #expect(try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, ObserverSettings(), now: 6000, in: $0) } == 0)
    }

    @Test func 자동_평가가_꺼져_있으면_넣지_않는다() throws {
        try markMerged(3000)
        var s = ObserverSettings()
        s.autoEvaluate = false
        #expect(try db.write { try EvaluationJob.enqueueLateEligible(firstStart: 1000, s, now: 6000, in: $0) } == 0)
    }

    /// 시나리오 4 — 평가 중 앱이 꺼졌다. 재시작하면 interrupted 로 닫고 같은 계기로 한 번만 다시 큐에.
    @Test func 중단된_실행은_한_번만_다시_큐에() throws {
        let run = try queue(.auto)
        try db.write { try $0.execute(sql: "UPDATE evaluation_run SET status = 'running' WHERE id = ?", arguments: [run.id]) }
        #expect(try db.write { try EvaluationJob.recover(now: 9000, in: $0) } == 1)
        #expect(try db.write { try EvaluationJob.recover(now: 9001, in: $0) } == 0)
        let runs = try db.read { try EvaluationRun.order(Column("created_at")).fetchAll($0) }
        #expect(runs.map(\.status) == [.interrupted, .queued])
        #expect(runs[1].trigger == .auto)
    }

    /// R4a — 서브에이전트 툴 행은 부모 턴 집계에 이미 들어 있어 다이제스트 입력에서 뺀다.
    @Test func 서브에이전트_툴은_다이제스트_입력에서_빠진다() throws {
        try db.write {
            try ObsTool(turnId: "t1", transcriptPath: "/gone/sess-aaaa-1/subagents/agent-1.jsonl", toolUseId: "sub1", name: "Bash",
                        target: "ls", startedTs: 1203, resultTs: 1204).insert($0)
        }
        let input = try db.read { db in
            try EvaluationJob.gather(try #require(try WorkUnit.fetchOne(db, key: "u1")), dirs: dirs, db: db)
        }
        #expect(input.tools.map(\.toolUseId) == ["x"])
    }

    /// Codex 서브에이전트 rollout 은 경로에 `subagents/` 가 없다 — "툴의 파일 ≠ 그 턴의 파일" 로 똑같이 뺀다.
    @Test func 코덱스_서브에이전트_툴도_다이제스트_입력에서_빠진다() throws {
        try db.write {
            try ObsTool(turnId: "t1", transcriptPath: "/c/2026/11/20/rollout-2026-11-20T01-00-00-sub-1.jsonl",
                        toolUseId: "exec-1", name: "Bash", target: "ls", startedTs: 1203, resultTs: 1204).insert($0)
            try ObsTool(turnId: "t1", transcriptPath: "/gone/a.jsonl", toolUseId: "y", name: "Agent",
                        target: "/root/sub", startedTs: 1205).insert($0)
        }
        let input = try db.read { db in
            try EvaluationJob.gather(try #require(try WorkUnit.fetchOne(db, key: "u1")), dirs: dirs, db: db)
        }
        #expect(input.tools.map(\.toolUseId) == ["x", "y"])
    }

    /// R10a — 같은 세션이어도 단위 시간 창 밖의 승인 요청은 제외.
    @Test func 단위_창_밖의_승인_요청은_제외() throws {
        try db.write {
            try ObsPermission(id: "p-in", ccSessionId: "sess-aaaa-1", ts: 1500).insert($0)
            try ObsPermission(id: "p-late", ccSessionId: "sess-aaaa-1", ts: 2001).insert($0)
            try ObsPermission(id: "p-early", ccSessionId: "sess-aaaa-1", ts: 999).insert($0)
        }
        let input = try db.read { db in
            try EvaluationJob.gather(try #require(try WorkUnit.fetchOne(db, key: "u1")), dirs: dirs, db: db)
        }
        #expect(input.permissions.map(\.id) == ["p-in"])
    }
}
