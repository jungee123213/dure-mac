// Dure/DureTests/ObsCollectorTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct FakeResolver: RepoResolving {
    var repos: [String: RepoInfo]
    func info(forCwd cwd: String) -> RepoInfo? {
        repos.first { cwd == $0.key || cwd.hasPrefix($0.key + "/") }?.value
    }
}

struct ObsCollectorTests {

    let dir: URL
    let db: DatabaseQueue
    let config: CollectConfig
    let resolver = FakeResolver(repos: [
        "/r/ios": RepoInfo(root: "/r/ios", defaultBranch: "main", githubRepo: "Moa-Map/moamap-iOS"),
    ])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("obs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
        db = try Fx.memoryDB()
        config = CollectConfig(projectsDir: dir, excludes: ["/private/tmp/", "/Users/me/.dure/observer/"],
                               workspacesRoot: "/Users/me/.dure/workspaces", timeZone: TimeZone(identifier: "UTC")!, chunk: 2)
    }

    @discardableResult
    func write(_ name: String, _ lines: [String], append: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("proj/\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.map { $0 + "\n" }.joined()
        if append, let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
        // mtime 해상도 1초 — 같은 초 안의 재기록을 "안 바뀜" 으로 보지 않게 테스트에서는 민다.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 10...100000))],
                                              ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func collect() throws -> ObsCollector.Report { try ObsCollector.collect(db: db, config: config, resolver: resolver) }
    func unit() throws -> WorkUnit { try db.read { try #require(try WorkUnit.fetchOne($0)) } }
    func turn() throws -> ObsTurn { try db.read { try #require(try ObsTurn.fetchOne($0)) } }

    @Test func 터미널과_두레_세션이_같은_브랜치면_한_단위() throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/r/ios');
                INSERT INTO agent (dure_session, workspace_id, repo_id, agent_kind, state, started_at)
                    VALUES ('a1', 'w1', 'r1', 'claude', 'done', 1);
                INSERT INTO cc_session (cc_session_id, dure_session, transcript_path, source, started_at)
                    VALUES ('dure-s', 'a1', '/x', 'startup', 1);
                """)
        }
        try write("term", [Fx.human("스플래시 만들자", session: "term-s"), Fx.human("색 바꿔", session: "term-s", ts: "2026-10-10T02:00:00.000Z")])
        try write("dure", [Fx.human("빌드 확인", session: "dure-s", ts: "2026-10-10T03:00:00.000Z")])
        #expect(try collect().turns == 3)
        let u = try unit()
        #expect(try db.read { try WorkUnit.fetchCount($0) } == 1)
        #expect(u.humanTurns == 3 && u.issueNo == 52 && u.workspaceId == "w1" && u.githubRepo == "Moa-Map/moamap-iOS")
        #expect(u.sourceRevision == 3)
        #expect(Set(try db.read { try ObsTurn.fetchAll($0) }.map(\.origin)) == [.terminal, .dureRepo])
    }

    @Test func 세션_안에서_브랜치를_바꾸면_다른_단위() throws {
        try write("s", [Fx.human("a", branch: "feat/#52/x"), Fx.human("b", branch: "fix/#53/y", ts: "2026-10-10T02:00:00.000Z")])
        try collect()
        #expect(try db.read { try WorkUnit.fetchCount($0) } == 2)
    }

    @Test func 감시자_자신의_세션은_경로와_세션_ID_로_뺀다() throws {
        try db.write { try ObserverSession(sessionId: "eval-1", kind: "eval", createdAt: 0).insert($0) }
        try write("self", [Fx.human("리포트를 읽어라", cwd: "/Users/me/.dure/observer/units/u1/runs/r1")])
        try write("tmp", [Fx.human("스파이크", cwd: "/private/tmp/claude-501/x")])
        // cwd 가 레포여도 앱이 띄운 세션이면 뺀다(이슈 초안 · 묻기 같은 후속 기능 대비, 리뷰 P2).
        try write("byid", [Fx.human("평가", session: "eval-1"),
                           Fx.toolUse("t1", name: "Read", input: ["file_path": "/r/ios/a"], session: "eval-1")])
        #expect(try collect().turns == 0)
        #expect(try db.read { try WorkUnit.fetchCount($0) } == 0)
        #expect(try db.read { try ObsTool.fetchCount($0) } == 0)
    }

    @Test func 툴_결과_답_길이_중단을_현재_턴에_붙인다() throws {
        try write("s", [
            Fx.human("옮겨줘"),
            Fx.toolUse("t1", name: "Bash", input: ["command": "xcodebuild build"], ts: "2026-10-10T01:00:02.000Z"),
            Fx.toolResult("t1", isError: true, content: "error: build failed", ts: "2026-10-10T01:00:40.000Z"),
            Fx.toolUse("t2", name: "Edit", input: ["file_path": "/r/ios/A.swift"], ts: "2026-10-10T01:00:41.000Z", messageId: "msg_E"),
            Fx.text("끝났습니다", messageId: "msg_A"),
            Fx.duration(41_000),
            Fx.interrupted(),
        ])
        try collect()
        let t = try turn()
        let tools = try db.read { try ObsTool.order(Column("started_ts")).fetchAll($0) }
        #expect(tools.count == 2)
        #expect(tools[0].isError && tools[0].errorHead == "error: build failed" && tools[0].resultTs! - tools[0].startedTs == 38)
        #expect(t.answerTail == "끝났습니다" && t.durationMs == 41_000 && t.interrupted)
        #expect(try unit().editCount == 1)
    }

    /// 리뷰 P1-I — A→B→A 처럼 같은 응답이 떨어져 기록돼도 한 번만.
    @Test func 비연속_중복_메시지는_한_번만() throws {
        try write("s", [Fx.human("a"), Fx.text("1", messageId: "msg_A"), Fx.text("2", messageId: "msg_B"), Fx.text("3", messageId: "msg_A")])
        try collect()
        let t = try turn()
        #expect(t.tokensHeadline == 2 * (2 + 8 + 30))
        #expect(t.tokensCacheCreation == 16 && t.tokensCacheRead == 1000)
        #expect(try db.read { try ObsUsage.fetchCount($0) } == 2)
    }

    /// 리뷰 P1-I · 실측 — 서브에이전트 기록은 `<세션>/subagents/*.jsonl` 에 따로 있다.
    @Test func 서브에이전트_파일의_토큰과_툴은_부모_턴에() throws {
        try write("s1", [Fx.human("조사해", ts: "2026-10-10T01:00:00.000Z"), Fx.human("다음", ts: "2026-10-10T02:00:00.000Z")])
        try write("s1/subagents/agent-abc", [
            Fx.toolUse("st1", name: "Read", input: ["file_path": "/r/ios/A.swift"], ts: "2026-10-10T01:10:00.000Z",
                       sidechain: true, messageId: "msg_S1"),
            Fx.toolResult("st1", ts: "2026-10-10T01:10:01.000Z", sidechain: true),
            Fx.text("찾았다", ts: "2026-10-10T01:10:02.000Z", messageId: "msg_S2", sidechain: true),
        ])
        try collect()
        let turns = try db.read { try ObsTurn.order(Column("ts")).fetchAll($0) }
        #expect(turns.count == 2)
        #expect(turns[0].sidechainTools == 1)
        #expect(turns[0].sidechainTokens == (10 + 5 + 20) + (2 + 8 + 30))
        #expect(turns[0].answerTail == nil)              // 서브에이전트 답은 사람 대화가 아니다
        #expect(turns[1].sidechainTokens == 0)
        // 재읽기 중복 방지용으로 서브에이전트 툴도 한 행 남는다(부모 턴에 연결).
        #expect(try db.read { try ObsTool.fetchCount($0) } == 1)
    }

    /// 리뷰 `subagentRemainsWithLaunchingTask` — 백그라운드 서브에이전트가 도는 사이 다음 턴이 시작돼도
    /// 서브에이전트 파일 하나는 처음 고른 부모 턴 하나에 붙는다.
    @Test func 서브에이전트는_띄운_작업에_남는다() throws {
        try write("s1", [Fx.human("조사해", ts: "2026-10-10T01:00:00.000Z"), Fx.human("다음", ts: "2026-10-10T02:00:00.000Z")])
        try write("s1/subagents/agent-abc", [
            Fx.toolUse("c1", name: "Read", input: ["file_path": "/r/ios/A.swift"], ts: "2026-10-10T01:59:00.000Z",
                       sidechain: true, messageId: "child1"),
            Fx.text("계속", ts: "2026-10-10T02:01:00.000Z", messageId: "child2", sidechain: true),
        ])
        try collect()
        var turns = try db.read { try ObsTurn.order(Column("ts")).fetchAll($0) }
        #expect(turns[0].sidechainTokens == (10 + 5 + 20) + (2 + 8 + 30))
        #expect(turns[1].sidechainTokens == 0)
        // 재시작(새 수집 상태)으로 같은 파일에 줄이 더 붙어도 같은 부모로 간다.
        try write("s1/subagents/agent-abc", [
            Fx.text("또", ts: "2026-10-10T02:05:00.000Z", messageId: "child3", sidechain: true),
        ], append: true)
        try collect()
        turns = try db.read { try ObsTurn.order(Column("ts")).fetchAll($0) }
        #expect(turns[0].sidechainTokens == (10 + 5 + 20) + 2 * (2 + 8 + 30))
        #expect(turns[1].sidechainTokens == 0)
    }

    /// 부모 세션 파일이 아직 수집 전이면 서브에이전트 커서를 올리지 않는다 — 다음 수집에서 다시 읽는다.
    @Test func 부모가_아직_없으면_서브에이전트_커서를_올리지_않는다() throws {
        try write("s1", [Fx.human("조사해", ts: "2026-10-10T01:00:00.000Z")])
        let sub = try write("s1/subagents/agent-abc", [
            Fx.text("찾았다", ts: "2026-10-10T01:10:02.000Z", messageId: "m1", sidechain: true),
        ])
        let r = try ObsCollector.ingest(file: sub, db: db, config: config, resolver: resolver)
        #expect(r.filesRead == 0)
        #expect(try db.read { try ObsCursor.fetchOne($0, key: sub.path) } == nil)
        try collect()
        #expect(try turn().sidechainTokens > 0)
    }

    /// 부모 파일이 아예 없으면(지워짐) 영원히 붙잡지 않고 예전처럼 건너뛰며 커서를 올린다.
    @Test func 부모_파일이_없으면_건너뛰고_커서를_올린다() throws {
        try write("gone/subagents/agent-abc", [
            Fx.text("찾았다", ts: "2026-10-10T01:10:02.000Z", messageId: "m1", sidechain: true),
        ])
        try collect()
        #expect(try db.read { try ObsCursor.fetchCount($0) } == 1)   // 경로 표기(/var ↔ /private/var)와 무관하게 센다
        #expect(try db.read { try ObsUsage.fetchCount($0) } == 0)
    }

    @Test func 바뀌지_않은_파일은_다시_읽지_않는다() throws {
        try write("s", [Fx.human("a")])
        #expect(try collect().filesRead == 1)
        #expect(try collect().filesRead == 0)
    }

    @Test func 덧붙은_줄만_읽는다() throws {
        try write("s", [Fx.human("a")])
        try collect()
        try write("s", [Fx.human("b", ts: "2026-10-10T02:00:00.000Z")], append: true)
        #expect(try collect().turns == 1)
        #expect(try db.read { try ObsTurn.fetchCount($0) } == 2)
    }

    /// 리뷰 P1-I — 같은 크기 이상으로 교체돼도 지문(첫 줄 uuid)으로 알아챈다. 같은 사건은 event_id 로 한 번만.
    @Test func 파일이_교체되면_처음부터_다시_읽되_중복이_없다() throws {
        try write("s", [Fx.human("a", uuid: "ev-a"), Fx.human("b", ts: "2026-10-10T02:00:00.000Z", uuid: "ev-b")])
        try collect()
        try write("s", [Fx.human("새 시작", uuid: "ev-new"), Fx.human("a", uuid: "ev-a"),
                        Fx.human("c", ts: "2026-10-10T03:00:00.000Z", uuid: "ev-c")])
        try collect()
        let ids = Set(try db.read { try ObsTurn.fetchAll($0) }.map(\.eventId))
        #expect(ids == ["ev-a", "ev-b", "ev-new", "ev-c"])
    }

    @Test func 깨진_줄과_모르는_type_을_따로_센다() throws {
        try write("s", [Fx.human("a"), "{broken", #"{"type":"user","message":{"content":"x"}}"#, #"{"type":"brand-new"}"#])
        let r = try collect()
        #expect(r.badLines == 2 && r.unknownTypes == 1)
        #expect(try db.read { try ObsCollector.unknownTypeCount(in: $0) } == 1)
    }

    @Test func 머지_뒤_턴은_새_세대_늦게_온_옛_턴은_옛_세대() throws {
        try write("s", [Fx.human("a", ts: "2026-10-10T01:00:00.000Z")])
        try collect()
        let merged = ObsParser.epoch("2026-10-10T02:00:00.000Z")!
        try db.write { try $0.execute(sql: "UPDATE work_unit SET merged_at = ?", arguments: [merged]) }
        try write("s", [Fx.human("머지 뒤", ts: "2026-10-10T03:00:00.000Z")], append: true)
        try write("late", [Fx.human("늦게 수집된 옛 턴", session: "s9", ts: "2026-10-10T01:30:00.000Z")])
        try collect()
        let units = try db.read { try WorkUnit.order(Column("generation")).fetchAll($0) }
        #expect(units.map(\.generation) == [0, 1])
        #expect(units[0].humanTurns == 2 && units[1].humanTurns == 1)
    }

    @Test func 배분_메시지는_peer_턴() throws {
        try write("s", [Fx.peer("[두레] 조율자 배분 #7 — ios")])
        try collect()
        let u = try unit()
        #expect(u.peerTurns == 1 && u.humanTurns == 0 && u.activity == 1)
        #expect(try turn().promptKind == .peer)
    }

    @Test func 조율자_세션() throws {
        try db.write { try $0.execute(sql: "INSERT INTO workspace (id, name) VALUES ('w1', '모아맵')") }
        try write("o", [Fx.human("둘 다 고치자", cwd: "/Users/me/.dure/workspaces/w1", branch: nil)])
        try collect()
        #expect(try unit().kind == .orchestrator && unit().workspaceId == "w1")
        #expect(try turn().origin == .dureOrchestrator)
    }

    @Test func 폴더가_사라진_레포는_기록된_브랜치로_묶는다() throws {
        try write("s", [Fx.human("a", cwd: "/gone/old-repo", branch: "feat/#9/x")])
        try collect()
        #expect(try unit().kind == .issueBranch && unit().repoRoot == "/gone/old-repo")
    }

    /// 리뷰 P1-I — 누적 전체가 아니라 최근 기준.
    @Test func 형식_경고는_최근_기준() throws {
        try db.write { db in
            try ObsCursor(path: "/a", byteOffset: 0, lineNo: 0, mtime: 0, size: 0, recentBad: 60, recentTotal: 200).insert(db)
        }
        #expect(try db.read { try ObsCollector.formatWarning(in: $0) })
        try db.write { try $0.execute(sql: "UPDATE obs_cursor SET recent_bad = 10") }
        #expect(try db.read { try ObsCollector.formatWarning(in: $0) } == false)
    }

    /// 리뷰 P7 — 형제 폴더(`workspaces-old`)를 조율자로 오인하지 않는다.
    @Test func 이름만_비슷한_형제_폴더는_조율자가_아니다() throws {
        try write("s", [Fx.human("a", cwd: "/Users/me/.dure/workspaces-old/x", branch: nil)])
        try collect()
        #expect(try turn().origin != .dureOrchestrator)
    }

    /// 리뷰 P8 — 파일 수정은 누가 했든 자격(editCount)에 센다.
    @Test func 서브에이전트가_한_수정도_편집으로_센다() throws {
        try write("s1", [Fx.human("고쳐", ts: "2026-10-10T01:00:00.000Z")])
        try write("s1/subagents/agent-abc", [
            Fx.toolUse("st1", name: "Edit", input: ["file_path": "/r/ios/A.swift"], ts: "2026-10-10T01:10:00.000Z",
                       sidechain: true, messageId: "msg_S1"),
        ])
        try collect()
        #expect(try unit().editCount == 1)
    }

    /// 리뷰 R4a — 서브에이전트 파일을 처음부터 다시 읽어도 카운터가 부풀지 않는다.
    @Test func 서브에이전트_파일을_다시_읽어도_카운터가_그대로() throws {
        try write("s1", [Fx.human("고쳐", ts: "2026-10-10T01:00:00.000Z")])
        let edit = Fx.toolUse("st1", name: "Edit", input: ["file_path": "/r/ios/A.swift"], ts: "2026-10-10T01:10:00.000Z",
                              sidechain: true, messageId: "msg_S1")
        try write("s1/subagents/agent-abc", [edit])
        try collect()
        // 첫 줄이 달라져 지문이 바뀌면 처음부터 다시 읽는다.
        try write("s1/subagents/agent-abc", [Fx.toolResult("zz", ts: "2026-10-10T01:09:00.000Z", sidechain: true), edit])
        try collect()
        #expect(try turn().sidechainTools == 1)
        #expect(try unit().editCount == 1)
        #expect(try db.read { try ObsTool.filter(Column("tool_use_id") == "st1").fetchCount($0) } == 1)
    }

    // MARK: - 평가 입력이 바뀌면 revision · last_ts (이슈 #27 Task 2)

    @Test func 툴_결과가_들어오면_평가_뒤_변경이_된다() throws {
        try write("s", [Fx.human("빌드해줘"),
                        Fx.toolUse("t1", name: "Bash", input: ["command": "xcodebuild build"], ts: "2026-10-10T01:00:02.000Z")])
        try collect()
        let before = try unit()
        try write("s", [Fx.toolResult("t1", isError: true, content: "error: build failed", ts: "2026-10-10T01:00:40.000Z")], append: true)
        try collect()
        let after = try unit()
        #expect(after.sourceRevision > before.sourceRevision)
        #expect(after.lastTs > before.lastTs)
    }

    @Test func 같은_결과를_다시_읽어도_revision_은_그대로() throws {
        let lines = [Fx.human("빌드해줘", uuid: "u-1"),
                     Fx.toolUse("t1", name: "Bash", input: ["command": "xcodebuild build"], ts: "2026-10-10T01:00:02.000Z"),
                     Fx.toolResult("t1", isError: true, content: "error: build failed", ts: "2026-10-10T01:00:40.000Z"),
                     Fx.duration(41_000)]
        try write("s", lines)
        try collect()
        let before = try unit()
        // 첫 줄이 달라져 지문이 바뀌면 처음부터 다시 읽는다.
        try write("s", [Fx.toolResult("zz", ts: "2026-10-10T00:59:00.000Z")] + lines)
        try collect()
        let after = try unit()
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.lastTs == before.lastTs)
    }

    @Test func 서브에이전트_툴_결과도_revision_을_올린다() throws {
        try write("s1", [Fx.human("고쳐", ts: "2026-10-10T01:00:00.000Z")])
        try write("s1/subagents/agent-abc", [
            Fx.toolUse("st1", name: "Bash", input: ["command": "make"], ts: "2026-10-10T01:10:00.000Z", sidechain: true, messageId: "msg_S1"),
        ])
        try collect()
        let before = try unit()
        try write("s1/subagents/agent-abc", [Fx.toolResult("st1", isError: true, ts: "2026-10-10T01:11:00.000Z", sidechain: true)], append: true)
        try collect()
        let after = try unit()
        #expect(after.sourceRevision > before.sourceRevision)
        #expect(after.lastTs > before.lastTs)
    }

    @Test func 턴_길이와_중단과_답_갱신도_revision_을_올린다() throws {
        try write("s", [Fx.human("해줘"), Fx.text("일단", messageId: "msg_A")])
        try collect()
        var rev = try unit().sourceRevision
        let lastTs = try unit().lastTs
        try write("s", [Fx.duration(5_000)], append: true)
        try collect()
        #expect(try unit().sourceRevision > rev); rev = try unit().sourceRevision
        #expect(try unit().lastTs == lastTs)      // 길이 · 중단은 시각이 없어 last_ts 를 밀지 않는다
        try write("s", [Fx.interrupted()], append: true)
        try collect()
        #expect(try unit().sourceRevision > rev); rev = try unit().sourceRevision
        #expect(try unit().lastTs == lastTs)
        // 같은 message 의 추가 텍스트 — 토큰은 이미 셌지만 답 꼬리가 바뀐다.
        try write("s", [Fx.text("마무리", messageId: "msg_A")], append: true)
        try collect()
        #expect(try unit().sourceRevision > rev)
    }

    /// 리뷰 — 답이 둘 이상인 턴을 처음부터 다시 읽어도(꼬리가 오갔다 돌아옴) revision 은 그대로.
    @Test func 답이_여럿인_턴을_다시_읽어도_revision_은_그대로() throws {
        let rest = [Fx.text("빌드할게", ts: "2026-10-10T01:00:01.000Z", messageId: "msg_1"),
                    Fx.toolUse("t1", name: "Bash", input: ["command": "make"], ts: "2026-10-10T01:00:02.000Z"),
                    Fx.text("끝", ts: "2026-10-10T01:00:04.000Z", messageId: "msg_2"),
                    Fx.duration(5_000)]
        let first = Fx.human("해줘", uuid: "u-1")
        try write("s", [first] + rest)
        try collect()
        let before = try unit()
        try write("s", [Fx.human("해줘", ts: "2026-10-10T01:00:00.000Z", uuid: "u-1"), Fx.toolResult("zz", ts: "2026-10-10T00:59:00.000Z")] + rest)
        try collect()
        let after = try unit()
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.lastTs == before.lastTs)
    }

    /// 리뷰 R2a 재검토 — 같은 턴의 답 줄이 청크 경계에 걸려도(chunk 1 = 줄마다 경계) 다시 읽기는 revision 을 올리지 않는다.
    @Test func 청크_경계에_걸린_턴을_다시_읽어도_revision_은_그대로() throws {
        var cfg = config
        cfg.chunk = 1
        let rest = [Fx.text("빌드할게", ts: "2026-10-10T01:00:01.000Z", messageId: "msg_1"),
                    Fx.toolUse("t1", name: "Bash", input: ["command": "make"], ts: "2026-10-10T01:00:02.000Z"),
                    Fx.text("끝", ts: "2026-10-10T01:00:04.000Z", messageId: "msg_2"),
                    Fx.duration(5_000)]
        let human = Fx.human("해줘", uuid: "u-1")
        try write("s", [human] + rest)
        try ObsCollector.collect(db: db, config: cfg, resolver: resolver)
        let before = try unit()
        try write("s", [Fx.toolResult("zz", ts: "2026-10-10T00:59:00.000Z"), human] + rest)
        try ObsCollector.collect(db: db, config: cfg, resolver: resolver)
        let after = try unit()
        #expect(after.sourceRevision == before.sourceRevision)
        #expect(after.lastTs == before.lastTs)
    }
}
