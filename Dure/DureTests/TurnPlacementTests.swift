// Dure/DureTests/TurnPlacementTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

/// reflog 를 시각대로 흉내 낸다 — 루트마다 (시각, 바뀐 브랜치) 전환 목록. 첫 전환 이전은 모른다(`nil`).
struct TimelineResolver: RepoResolving {
    var repos: [String: RepoInfo]
    var switches: [String: [(ts: Int, to: String)]] = [:]
    func info(forCwd cwd: String) -> RepoInfo? {
        repos.first { cwd == $0.key || cwd.hasPrefix($0.key + "/") }?.value
    }
    func branch(atRoot root: String, ts: Int) -> String? {
        switches[root]?.last { $0.ts <= ts }?.to
    }
}

/// 이슈 #60 — 턴을 마지막 활동 때의 브랜치 · 아는 루트로 다시 놓는다(D-48).
struct TurnPlacementTests {

    let dir: URL
    let db: DatabaseQueue
    let config: CollectConfig
    /// `Fx.human` 기본 시각 2026-10-10T01:00:00Z.
    let t0 = 1_791_594_000

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proj"), withIntermediateDirectories: true)
        db = try Fx.memoryDB()
        config = CollectConfig(projectsDir: dir, excludes: ["/Users/me/.dure/observer/"],
                               workspacesRoot: "/Users/me/.dure/workspaces", timeZone: TimeZone(identifier: "UTC")!)
    }

    func resolver(_ switches: [(ts: Int, to: String)] = []) -> TimelineResolver {
        TimelineResolver(repos: ["/r/ios": RepoInfo(root: "/r/ios", defaultBranch: "main", githubRepo: "o/ios")],
                         switches: ["/r/ios": switches])
    }

    func write(_ name: String, _ lines: [String]) throws {
        let url = dir.appendingPathComponent("proj/\(name).jsonl")
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 10...100000))],
                                              ofItemAtPath: url.path)
    }

    func collect(_ r: RepoResolving) throws { try ObsCollector.collect(db: db, config: config, resolver: r) }
    func units() throws -> [WorkUnit] { try db.read { try WorkUnit.order(Column("first_ts")).fetchAll($0) } }
    func unitOf(prompt: String) throws -> WorkUnit {
        try db.read { db in
            let t = try #require(try ObsTurn.filter(Column("prompt") == prompt).fetchOne(db))
            return try #require(try WorkUnit.fetchOne(db, key: t.unitId))
        }
    }

    /// 턴 하나 + 본 세션 툴 하나(시작 +2초, 결과 +3초).
    func turnWithTool(_ prompt: String, branch: String, at ts: String = "2026-10-10T01:00:00.000Z",
                      toolAt: String = "2026-10-10T01:00:02.000Z", resultAt: String = "2026-10-10T01:00:03.000Z",
                      id: String = "tu1", name: String = "Edit") -> [String] {
        [Fx.human(prompt, branch: branch, ts: ts),
         Fx.toolUse(id, name: name, input: ["file_path": "/r/ios/a.swift"], ts: toolAt, messageId: "m-\(id)"),
         Fx.toolResult(id, ts: resultAt)]
    }

    // MARK: - 브랜치

    @Test func 턴_안에서_새_브랜치를_따면_그_브랜치_단위로_간다() throws {
        // main 에서 시작한 "이슈 올리고 고쳐줘" — +1초에 새 브랜치를 따고 +2초에 고친다.
        try write("a", turnWithTool("이슈 올리고 고쳐줘", branch: "main"))
        try collect(resolver([(t0 - 100, "main"), (t0 + 1, "fix/#60/observer")]))
        let u = try unitOf(prompt: "이슈 올리고 고쳐줘")
        #expect(u.kind == .issueBranch && u.branch == "fix/#60/observer" && u.issueNo == 60)
        #expect(u.editCount == 1 && u.humanTurns == 1)
        // 옮겨서 빈 main 날짜 단위는 지운다.
        #expect(try units().count == 1)
    }

    @Test func 툴_결과_시각까지_본다() throws {
        // `git switch -c` 자체가 마지막 툴이면 시작은 옛 브랜치, 결과는 새 브랜치다.
        try write("a", turnWithTool("브랜치 따줘", branch: "main", name: "Bash"))
        try collect(resolver([(t0 - 100, "main"), (t0 + 3, "fix/#61/x")]))
        #expect(try unitOf(prompt: "브랜치 따줘").branch == "fix/#61/x")
    }

    @Test func 툴이_없는_턴은_그대로다() throws {
        try write("a", [Fx.human("지금 상태 알려줘", branch: "main")])
        try collect(resolver([(t0 - 100, "fix/#9/other")]))
        #expect(try unitOf(prompt: "지금 상태 알려줘").branch == "main")
    }

    @Test func reflog_가_모르면_그대로다() throws {
        try write("a", turnWithTool("고쳐줘", branch: "feat/#52/x"))
        try collect(resolver())
        #expect(try unitOf(prompt: "고쳐줘").branch == "feat/#52/x")
    }

    @Test func reflog_가_HEAD_면_그대로다() throws {
        try write("a", turnWithTool("고쳐줘", branch: "feat/#52/x"))
        try collect(resolver([(t0 - 100, "HEAD")]))
        #expect(try unitOf(prompt: "고쳐줘").branch == "feat/#52/x")
    }

    @Test func 같은_브랜치면_쓰지_않는다() throws {
        try write("a", turnWithTool("고쳐줘", branch: "feat/#52/x"))
        let r = resolver([(t0 - 100, "feat/#52/x")])
        try collect(r)
        let before = try #require(try units().first).sourceRevision
        let moved = try db.write { try TurnPlacement.reconcile(in: $0, resolver: r, config: config) }
        #expect(moved == 0)
        #expect(try #require(try units().first).sourceRevision == before)
    }

    @Test func 머지_뒤_main_으로_돌아간_정리_턴은_빈_세대_대신_main_단위로() throws {
        let r = resolver([(t0 - 100, "feat/#52/x"), (t0 + 601, "main")])
        try write("a", [Fx.human("구현해", branch: "feat/#52/x")])
        try collect(r)
        try db.write { try $0.execute(sql: "UPDATE work_unit SET merged_at = ?, pr_number = 53", arguments: [t0 + 300]) }
        // 머지 뒤 같은 브랜치에서 시작해 main 으로 옮기고 정리한다.
        try write("b", turnWithTool("머지했어 정리해줘", branch: "feat/#52/x", at: "2026-10-10T01:10:00.000Z",
                                    toolAt: "2026-10-10T01:10:02.000Z", resultAt: "2026-10-10T01:10:03.000Z",
                                    id: "tu2", name: "Bash"))
        try collect(r)
        let cleanup = try unitOf(prompt: "머지했어 정리해줘")
        #expect(cleanup.kind == .defaultBranch && cleanup.branch == "main")
        let all = try units()
        #expect(all.count == 2)
        #expect(!all.contains { $0.branch == "feat/#52/x" && $0.generation == 1 })
        #expect(try unitOf(prompt: "구현해").prNumber == 53)
    }

    @Test func 서브에이전트_툴_시각은_보지_않는다() throws {
        // 본 세션 툴은 +2초(feat/#52/x), 서브에이전트 툴은 브랜치를 바꾼 뒤(+100초)까지 돈다.
        let r = resolver([(t0 - 100, "feat/#52/x"), (t0 + 50, "main")])
        try write("a", turnWithTool("고쳐줘", branch: "feat/#52/x"))
        try collect(r)
        try db.write { db in
            let t = try #require(try ObsTurn.fetchOne(db))
            try ObsTool(turnId: t.id, transcriptPath: t.transcriptPath + ".sub/subagents/x.jsonl", toolUseId: "sc1",
                        name: "Edit", target: nil, startedTs: t0 + 100).insert(db)
        }
        let moved = try db.write { try TurnPlacement.reconcile(in: $0, resolver: r, config: config) }
        #expect(moved == 0)
        #expect(try unitOf(prompt: "고쳐줘").branch == "feat/#52/x")
    }

    // MARK: - 지워진 레포 루트

    @Test func 지워진_레포_하위_폴더_세션은_아는_루트로_간다() throws {
        // 레포가 디스크에 없다 — resolver 도 모른다. 기록된 브랜치만 있다.
        let none = TimelineResolver(repos: [:])
        try write("a", [Fx.human("루트에서", cwd: "/gone/MoaMap", branch: "main")])
        try collect(none)
        try write("b", [Fx.human("하위 폴더에서", cwd: "/gone/MoaMap/app/src/main/res", branch: "main",
                                 ts: "2026-10-10T02:00:00.000Z")])
        try collect(none)
        #expect(try unitOf(prompt: "하위 폴더에서").repoRoot == "/gone/MoaMap")
        #expect(try units().count == 1)
    }

    @Test func 옛_하위_폴더_단위는_정합이_아는_루트로_옮긴다() throws {
        // v12 이전 수집이 하위 폴더를 루트로 만든 단위.
        try db.write { db in
            for (root, prompt, line) in [("/gone/MoaMap", "루트", 1), ("/gone/MoaMap/app/src", "하위", 2)] {
                let p = WorkUnitRules.place(cwd: root, branch: "main", repo: RepoInfo(root: root, defaultBranch: nil, githubRepo: nil),
                                            ts: t0, timeZone: config.timeZone, workspacesRoot: config.workspacesRoot)
                let u = try ObsCollector.unit(for: p, ts: t0, githubRepo: nil, db: db)
                try ObsTurn(unitId: u.id, eventId: "e\(line)", ccSessionId: "s1", transcriptPath: "/p/a.jsonl", lineNo: line,
                            origin: .terminal, promptKind: .human, entrypoint: "cli", ts: t0, prompt: prompt,
                            permissionMode: nil, agentKind: .claude).insert(db)
            }
        }
        let moved = try db.write { db in
            let n = try TurnPlacement.reconcile(in: db, resolver: TimelineResolver(repos: [:]), config: config, exists: { _ in false })
            try TurnPlacement.pruneEmpty(in: db)
            return n
        }
        #expect(moved == 1)
        #expect(try unitOf(prompt: "하위").repoRoot == "/gone/MoaMap")
        #expect(try units().count == 1)
    }

    @Test func 있는_경로는_아는_루트가_품어도_그대로다() {
        // 중첩 레포(서브모듈 · 워크트리)는 실제로 따로다.
        #expect(TurnPlacement.normalizedRoot("/r/app/sub", known: ["/r/app"], exists: { _ in true }) == "/r/app/sub")
        #expect(TurnPlacement.normalizedRoot("/r/app/sub", known: ["/r/app", "/r"], exists: { _ in false }) == "/r")
        #expect(TurnPlacement.normalizedRoot("/r/apple", known: ["/r/app"], exists: { _ in false }) == "/r/apple")
    }

    // MARK: - 빈 단위

    @Test func 빈_단위는_PR_이나_평가가_있으면_남긴다() throws {
        try db.write { db in
            for (key, pr) in [("a", nil), ("b", 7), ("c", nil)] as [(String, Int?)] {
                var u = WorkUnit(unitKey: key, baseKey: key, kind: .issueBranch, repoRoot: "/r", cwd: nil, branch: key,
                                 generation: 0, day: nil, issueNo: nil, githubRepo: nil, workspaceId: nil,
                                 firstTs: t0, lastTs: t0)
                u.id = key
                u.prNumber = pr
                try u.insert(db)
            }
            _ = try EvaluationJob.enqueue(unitID: "c", trigger: .manual, now: t0, in: db)
            #expect(try TurnPlacement.pruneEmpty(in: db) == 1)
        }
        #expect(try units().map(\.id).sorted() == ["b", "c"])
    }
}
