// Dure/DureTests/ObsCollectorCodexTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

/// Codex rollout(`sessions/YYYY/MM/DD/rollout-*.jsonl`) 수집. 줄 모양은 `CFx`(CodexObsParserTests) — 실측 모양.
struct ObsCollectorCodexTests {

    let dir: URL
    let sessions: URL
    let db: DatabaseQueue
    let config: CollectConfig
    let resolver = FakeResolver(repos: [
        "/r/ios": RepoInfo(root: "/r/ios", defaultBranch: "main", githubRepo: "Moa-Map/moamap-iOS"),
    ])

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("obs-codex-\(UUID().uuidString)")
        sessions = dir.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude/proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        db = try Fx.memoryDB()
        config = CollectConfig(projectsDir: dir.appendingPathComponent("claude"),
                               codexSessionsDir: sessions,
                               excludes: ["/private/tmp/", "/Users/me/.dure/observer/"],
                               workspacesRoot: "/Users/me/.dure/workspaces", timeZone: TimeZone(identifier: "UTC")!, chunk: 2)
    }

    /// 줄의 시각만 바꾼다.
    func at(_ ts: String, _ line: String) -> String {
        var o = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        o["timestamp"] = ts
        return Fx.json(o)
    }

    /// 서브에이전트 머리(실측 4절 모양): `id` = 자기 스레드, `session_id` = 루트, `parent_thread_id`, `source` 객체.
    func subMeta(_ id: String, parent: String?, ts: String) -> String {
        var extra: [String: Any] = ["source": ["subagent": "review"]]
        if let parent {
            extra["parent_thread_id"] = parent
            extra["source"] = ["subagent": ["thread_spawn": [
                "parent_thread_id": parent, "depth": 1, "agent_path": "/root/sub", "agent_nickname": "Harvey",
            ] as [String: Any]]]
        }
        return at(ts, CFx.meta(session: id, root: parent ?? id, threadSource: "subagent", extra: extra))
    }

    @discardableResult
    func rollout(_ name: String, _ lines: [String], append: Bool = false, day: String = "2026/11/20") throws -> URL {
        let url = sessions.appendingPathComponent("\(day)/rollout-\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.map { $0 + "\n" }.joined()
        if append, let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 10...100000))],
                                              ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func collect() throws -> ObsCollector.Report { try ObsCollector.collect(db: db, config: config, resolver: resolver) }
    func turns() throws -> [ObsTurn] { try db.read { try ObsTurn.order(Column("ts"), Column("line_no")).fetchAll($0) } }
    /// 목록이 돌려준 경로 표기(`/private/var` ↔ `/var`)와 무관하게 그 파일의 커서.
    func cursor(_ url: URL) throws -> ObsCursor? {
        try db.read { try ObsCursor.fetchAll($0) }.first { $0.path.hasSuffix("/" + url.lastPathComponent) }
    }
    func unit() throws -> WorkUnit { try db.read { try #require(try WorkUnit.fetchOne($0)) } }

    /// 사람 턴 하나 · 명령 둘(하나 실패) · 사용량 하나 · 답.
    func oneTurn(session: String = "th-1", cwd: String = "/r/ios", text: String = "고쳐줘", trigger: String? = "user",
                 originator: String? = "dure") -> [String] {
        [CFx.meta(session: session, cwd: cwd, originator: originator),
         CFx.taskStarted(trigger: trigger),
         CFx.turnContext(cwd: cwd),
         CFx.userItem(text),
         CFx.command(id: "c1", ["/bin/zsh", "-lc", "ls"]),
         CFx.command(id: "c2", ["/bin/zsh", "-lc", "false"], status: "failed", exit: 1, output: "boom\n"),
         CFx.usage(id: "resp-1", input: 10, cached: 4, write: 0, output: 3),
         CFx.agentItem("끝"),
         CFx.taskComplete(ms: 500)]
    }

    // MARK: -

    @Test func codexSessionBecomesTurnsAndTools() throws {
        try rollout("2026-11-20T01-00-00-th-1", oneTurn())
        let r = try collect()
        #expect(r.turns == 1 && r.badLines == 0 && r.unknownTypes == 0)
        let ts = try turns()
        try #require(ts.count == 1)
        let t = ts[0]
        #expect(t.agentKind == .codex)
        #expect(t.ccSessionId == "th-1" && t.eventId == "th-1:4" && t.entrypoint == "codex")
        #expect(t.prompt == "고쳐줘" && t.promptKind == .human)
        #expect(t.answerTail == "끝" && t.durationMs == 500 && t.model == "gpt-5.5-codex")
        // `input_tokens` 는 캐시 읽기를 포함한다 — 나눠 담는다. 답(AgentMessage)은 사용량 행을 만들지 않는다.
        #expect(t.tokensInput == 6 && t.tokensCacheRead == 4 && t.tokensOutput == 3 && t.tokensCacheCreation == 0)
        #expect(try db.read { try ObsUsage.fetchCount($0) } == 1)
        let tools = try db.read { try ObsTool.order(Column("tool_use_id")).fetchAll($0) }
        #expect(tools.map(\.name) == ["Bash", "Bash"])
        #expect(tools.map(\.isError) == [false, true])
        #expect(tools.allSatisfy { $0.turnId == t.id })
        let u = try unit()
        #expect(u.humanTurns == 1 && u.repoRoot == "/r/ios")
        // 다시 수집해도 그대로.
        #expect(try collect().filesRead == 0)
    }

    @Test func resumedCodexFileKeepsSession() throws {
        try rollout("2026-11-20T01-00-00-th-1", Array(oneTurn().prefix(4)))
        try collect()
        // 둘째 덩어리에는 머리도 `turn_context` 도 없다 — 첫 줄로 상태를 되살려 같은 세션 · cwd 로 읽어야 한다.
        try rollout("2026-11-20T01-00-00-th-1", [
            at("2026-11-20T02:00:00.000Z", CFx.taskStarted(turn: "t2")),
            at("2026-11-20T02:00:01.000Z", CFx.userItem("둘째", turn: "t2")),
            at("2026-11-20T02:00:02.000Z", CFx.command(id: "c9", ["/bin/zsh", "-lc", "ls"])),
        ], append: true)
        #expect(try collect().turns == 1)
        let ts = try turns()
        try #require(ts.count == 2)
        #expect(ts.allSatisfy { $0.ccSessionId == "th-1" && $0.agentKind == .codex })
        #expect(ts[1].eventId == "th-1:6" && ts[1].prompt == "둘째")
        #expect(try db.read { try WorkUnit.fetchCount($0) } == 1)
        #expect(try unit().repoRoot == "/r/ios" && unit().humanTurns == 2)
        let tool = try db.read { try #require(try ObsTool.fetchOne($0)) }
        #expect(tool.turnId == ts[1].id)
    }

    /// Codex Desktop(사용자가 직접 연 세션)도 Claude 터미널 세션과 같은 규칙 — 레포 안은 터미널 출처,
    /// 제외 폴더는 버린다. 레포 밖(제외 아님)은 Claude 처럼 날짜 단위(`no_git`)로 묶인다.
    @Test func desktopSessionInRepoIsTerminalOrigin() throws {
        try rollout("2026-11-20T01-00-00-desk-1", oneTurn(session: "desk-1", cwd: "/r/ios/App", originator: "Codex Desktop"))
        try rollout("2026-11-20T01-00-00-desk-2", oneTurn(session: "desk-2", cwd: "/private/tmp/spike"))
        try collect()
        let ts = try turns()
        try #require(ts.count == 1)
        #expect(ts[0].origin == .terminal && ts[0].ccSessionId == "desk-1")
        #expect(try unit().repoRoot == "/r/ios")

        try rollout("2026-11-20T01-00-00-desk-3", oneTurn(session: "desk-3", cwd: "/Users/me/Desktop"))
        try write(claude: "c", [Fx.human("같은 폴더", session: "cl-1", cwd: "/Users/me/Desktop", branch: nil,
                                         ts: "2026-11-20T03:00:00.000Z")])
        try collect()
        let outside = try db.read { try WorkUnit.filter(Column("cwd") == "/Users/me/Desktop").fetchAll($0) }
        #expect(outside.count == 1 && outside.first?.kind == .noGit)
        #expect(outside.first?.humanTurns == 2)      // Codex 하나 · Claude 하나가 같은 단위
    }

    /// 두레 Codex 페인 — SessionStart 훅이 스레드 id 를 `cc_session` 에 넣는다(= `session_meta.id`, 실측 7절).
    @Test func dureCodexPaneIsDureRepoOrigin() throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO workspace (id, name) VALUES ('w1', '모아맵');
                INSERT INTO repo (id, workspace_id, path) VALUES ('r1', 'w1', '/r/ios');
                INSERT INTO agent (dure_session, workspace_id, repo_id, agent_kind, state, started_at)
                    VALUES ('a1', 'w1', 'r1', 'codex', 'done', 1);
                INSERT INTO cc_session (cc_session_id, dure_session, transcript_path, source, started_at)
                    VALUES ('th-dure', 'a1', '/x', 'startup', 1);
                """)
        }
        try rollout("2026-11-20T01-00-00-th-dure", oneTurn(session: "th-dure"))
        try collect()
        let t = try #require(try turns().first)
        #expect(t.origin == .dureRepo && t.agentKind == .codex)
        #expect(try unit().workspaceId == "w1")
    }

    @Test func dispatchTurnIsPeerAndCounted() throws {
        try rollout("2026-11-20T01-00-00-th-1", oneTurn(text: "[두레] 조율자 배분 #7 — ios\n할 일", trigger: "queue"))
        try collect()
        let u = try unit()
        #expect(u.peerTurns == 1 && u.humanTurns == 0 && u.activity == 1)
        #expect(try turns().first?.promptKind == .peer)
    }

    /// 서브에이전트 파일(따로 rollout, `session_id` = 부모)은 부모 세션에서 그 시각 직전 턴에 붙는다.
    /// 파일 이름 순으로는 서브가 먼저 오게 지었다 — 머리를 읽어 본 세션 먼저 수집해야 한 번에 붙는다.
    @Test func codexSubagentAttachesToParentTurn() throws {
        try rollout("2026-11-20T01-00-00-th-1", [
            at("2026-11-20T01:00:00.000Z", CFx.meta(session: "th-1")),
            at("2026-11-20T01:00:00.000Z", CFx.taskStarted(turn: "t1")),
            at("2026-11-20T01:00:00.000Z", CFx.turnContext()),
            at("2026-11-20T01:00:00.000Z", CFx.userItem("조사해", turn: "t1")),
            at("2026-11-20T01:00:01.000Z", CFx.item(["type": "SubAgentActivity", "id": "call_14", "kind": "started",
                                                     "agent_thread_id": "sub-1", "agent_path": "/root/sub"], turn: "t1")),
            at("2026-11-20T01:00:30.000Z", CFx.item(["type": "CollabAgentToolCall", "id": "call_15", "tool": "wait",
                                                     "status": "completed"], turn: "t1")),
            at("2026-11-20T01:00:40.000Z", CFx.agentItem("부모 답", turn: "t1")),
            at("2026-11-20T02:00:00.000Z", CFx.taskStarted(turn: "t2")),
            at("2026-11-20T02:00:00.000Z", CFx.userItem("다음", turn: "t2")),
        ])
        let sub = try rollout("2026-11-20T00-00-00-sub-1", subagentLines("sub-1", parent: "th-1"))
        try collect()
        let ts = try turns()
        try #require(ts.count == 2)
        #expect(ts[0].sidechainTools == 2)
        #expect(ts[0].sidechainTokens == 6 + 0 + 3)
        #expect(ts[0].answerTail == "부모 답")            // 서브 답은 사람 대화가 아니다
        #expect(ts[0].tokensInput == 0)
        #expect(ts[1].sidechainTools == 0 && ts[1].sidechainTokens == 0)
        let tools = try db.read { try ObsTool.fetchAll($0) }
        // 부모의 `Agent`(띄우기) 하나 + 서브 명령 · 수정. 협업 `wait` 은 안 센다.
        #expect(tools.count == 3)
        #expect(tools.filter { $0.turnId == ts[0].id }.count == 3)
        #expect(tools.contains { $0.name == "Bash" && $0.isError })
        #expect(try db.read { try ObsUsage.filter(Column("sidechain") == true).fetchCount($0) } == 1)
        #expect(try unit().editCount == 1)
        // 서브 파일을 처음부터 다시 읽어도(커서 잃음) 카운터가 그대로 — 부모는 저장된 툴 행으로 다시 찾는다.
        let stale = try #require(try cursor(sub))
        try db.write { _ = try stale.delete($0) }
        try collect()
        #expect(try turns()[0].sidechainTools == 2 && turns()[0].sidechainTokens == 9)
    }

    func subagentLines(_ id: String, parent: String?) -> [String] {
        [subMeta(id, parent: parent, ts: "2026-11-20T01:00:02.000Z"),
         at("2026-11-20T01:00:02.000Z", Fx.json(["timestamp": "x", "ordinal": 1, "type": "event_msg", "payload": [
            "type": "task_started", "turn_id": "st1",
            "turn_attribution": ["turn_id": "st1", "turn_trigger": NSNull(), "parent_turn_id": "t1", "root_turn_id": "t1"],
         ] as [String: Any]])),
         at("2026-11-20T01:00:02.000Z", CFx.turnContext(turn: "st1")),
         at("2026-11-20T01:00:03.000Z", CFx.usage(id: "resp-s1", input: 10, cached: 4, write: 0, output: 3)),
         at("2026-11-20T01:00:04.000Z", CFx.command(id: "exec-1", ["/bin/zsh", "-lc", "echo sub; exit 2"], status: "failed",
                                                    exit: 2, output: "sub\n")),
         at("2026-11-20T01:00:05.000Z", CFx.item(["type": "FileChange", "id": "exec-2", "status": "completed",
                                                  "changes": ["/r/ios/sub.txt": ["type": "add", "content": "x\n"]]],
                                                 turn: "st1")),
         at("2026-11-20T01:00:06.000Z", CFx.agentItem("서브 끝", turn: "st1")),
         at("2026-11-20T01:00:07.000Z", CFx.taskComplete(turn: "st1", ms: 151))]
    }

    /// 부모 세션 파일이 아직 수집 전이면 서브 커서를 올리지 않는다 — 다음 수집에서 붙는다.
    @Test func codexSubagentWaitsForParentFile() throws {
        try rollout("2026-11-20T01-00-00-th-1", [
            at("2026-11-20T01:00:00.000Z", CFx.meta(session: "th-1")),
            at("2026-11-20T01:00:00.000Z", CFx.turnContext()),
            at("2026-11-20T01:00:00.000Z", CFx.userItem("조사해", turn: "t1")),
        ], day: "2026/11/19")       // 날짜 폴더가 달라도 이름(끝 uuid)으로 찾는다
        let sub = try rollout("2026-11-20T00-00-00-sub-1", subagentLines("sub-1", parent: "th-1"))
        let r = try ObsCollector.ingest(file: sub, db: db, config: config, resolver: resolver)
        #expect(r.filesRead == 0)
        #expect(try cursor(sub) == nil)
        try collect()
        #expect(try turns().first?.sidechainTools == 2)
    }

    /// 부모 표시가 없는 서브에이전트 파일은 본 세션으로 세지 않고 건너뛴다(커서는 끝으로).
    @Test func codexSubagentWithoutParentSkipped() throws {
        try rollout("2026-11-20T01-00-00-th-1", Array(oneTurn().prefix(4)))
        let sub = try rollout("2026-11-20T01-30-00-sub-x", subagentLines("sub-x", parent: nil))
        try collect()
        #expect(try turns().count == 1 && turns()[0].sidechainTools == 0 && turns()[0].sidechainTokens == 0)
        #expect(try db.read { try ObsTool.fetchCount($0) } == 0)
        #expect(try cursor(sub) != nil)
    }

    /// 가져온 Claude 세션(`history_mode: legacy`) — Claude 트랜스크립트와 이중으로 세지 않는다. 다시 읽지도 않는다.
    @Test func importedLegacySessionSkipped() throws {
        let url = try rollout("2026-11-20T01-00-00-imp-1", [
            CFx.meta(session: "imp-1", originator: "Codex Desktop", historyMode: "legacy"),
            CFx.taskStarted(), CFx.userMessageEvent("가져온 글"), CFx.userItem("가져온 글"),
        ])
        #expect(try collect().turns == 0)
        #expect(try db.read { try ObsTurn.fetchCount($0) } == 0)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        #expect(try cursor(url)?.byteOffset == size)
    }

    /// 오래 쉰 rollout 은 zstd 로 압축된다 — 읽지 않는다(macOS 기본 라이브러리에 zstd 가 없다).
    @Test func compressedRolloutIsNotRead() throws {
        let url = sessions.appendingPathComponent("2026/11/01/rollout-2026-11-01T01-00-00-old.jsonl.zst")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x28, 0xb5, 0x2f, 0xfd, 0, 1, 2]).write(to: url)
        try rollout("2026-11-20T01-00-00-th-1", oneTurn())
        let r = try collect()
        #expect(r.filesRead == 1 && r.badLines == 0)
        #expect(!ObsCollector.codexFiles(in: sessions).contains { $0.lastPathComponent.hasSuffix(".zst") })
    }

    @Test func codexFilesListsMainsBeforeSubagents() throws {
        try rollout("2026-11-20T00-00-00-sub-1", subagentLines("sub-1", parent: "th-1"))
        try rollout("2026-11-20T01-00-00-th-1", oneTurn(), day: "2026/11/19")
        try rollout("2026-11-20T02-00-00-th-2", oneTurn(session: "th-2"))
        try Data("x\n".utf8).write(to: sessions.appendingPathComponent("2026/11/20/notes.jsonl"))
        let names = ObsCollector.codexFiles(in: sessions).map(\.lastPathComponent)
        #expect(names == ["rollout-2026-11-20T01-00-00-th-1.jsonl", "rollout-2026-11-20T02-00-00-th-2.jsonl",
                          "rollout-2026-11-20T00-00-00-sub-1.jsonl"])
    }

    /// 압축 줄(`compacted`)은 수백 KB 다(사용자 실제 최대 880KB) — 깨진 줄로 세지 않는다.
    @Test func hugeCompactedLineIsNotBroken() throws {
        var lines = Array(oneTurn().prefix(4))
        lines.append(CFx.line("compacted", ["message": String(repeating: "가", count: 300_000), "replacement_history": []]))
        try rollout("2026-11-20T01-00-00-th-1", lines)
        let r = try collect()
        #expect(r.badLines == 0)
        #expect(try turns().first?.compacted == true)
    }

    /// Codex 를 켜도 Claude 수집은 그대로 — Claude 턴은 `agent_kind == claude`.
    @Test func claudeCollectionUnchanged() throws {
        try write(claude: "s", [Fx.human("고쳐줘", ts: "2026-10-10T01:00:00.000Z")])
        try rollout("2026-11-20T01-00-00-th-1", oneTurn())
        #expect(try collect().turns == 2)
        let kinds = try turns().map(\.agentKind)
        #expect(kinds == [.claude, .codex])
        // Codex 디렉터리가 없으면(nil) Codex 는 수집하지 않는다.
        var off = config; off.codexSessionsDir = nil
        let db2 = try Fx.memoryDB()
        _ = try ObsCollector.collect(db: db2, config: off, resolver: resolver)
        #expect(try db2.read { try ObsTurn.fetchAll($0) }.map(\.agentKind) == [.claude])
    }

    @Test func observerDirsPointAtCodexSessions() {
        let d = ObserverDirs(root: URL(fileURLWithPath: "/h/.dure/observer"), claudeHome: URL(fileURLWithPath: "/h/.claude"),
                             workspacesRoot: URL(fileURLWithPath: "/h/.dure/workspaces"),
                             settingsDir: URL(fileURLWithPath: "/h/.dure/settings"), codexHome: URL(fileURLWithPath: "/h/.codex"))
        #expect(d.codexSessions?.path == "/h/.codex/sessions")
        #expect(ObserverPaths.live.codexSessions?.path.hasSuffix("/.codex/sessions") == true)
    }

    func write(claude name: String, _ lines: [String]) throws {
        let url = dir.appendingPathComponent("claude/proj/\(name).jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }
}
