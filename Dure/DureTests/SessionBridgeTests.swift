import Foundation
import GRDB
import Testing
@testable import Dure

/// Step 4 · F2 — 훅 이벤트 → 매핑 테이블.
/// **아래 두 픽스처는 shim 이 실제로 만든 파일을 그대로 옮긴 것이다.** 손으로 지어낸
/// 모양을 테스트하면 정작 실물이 바뀌었을 때 못 잡는다.
struct SessionBridgeTests {

    static let sessionStartJSON = """
    {"v":1,"ts":"2026-09-02T05:13:51Z","ev":"SessionStart","agent_kind":"claude",\
    "dure_session":"fixture-pane","payload":{"session_id":"cc-aaa",\
    "transcript_path":"/Users/x/.claude/projects/p/cc-aaa.jsonl","cwd":"/Users/x/repo",\
    "hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}}
    """

    static let promptSubmitJSON = """
    {"v":1,"ts":"2026-09-02T05:13:51Z","ev":"UserPromptSubmit","agent_kind":"claude",\
    "dure_session":"fixture-pane"}
    """

    static func event(_ json: String) throws -> HookEvent {
        try #require(HookEvent(data: Data(json.utf8)))
    }

    // MARK: - 파싱

    @Test func SessionStart_가_브리지에_필요한_값을_전부_싣는다() throws {
        let e = try Self.event(Self.sessionStartJSON)
        #expect(e.v == 1)
        #expect(e.isSupported)
        #expect(e.ev == "SessionStart")
        #expect(e.agentKind == "claude")
        #expect(e.dureSession == "fixture-pane")
        #expect(e.ccSessionID == "cc-aaa")
        #expect(e.transcriptPath == "/Users/x/.claude/projects/p/cc-aaa.jsonl")
        #expect(e.cwd == "/Users/x/repo")
        #expect(e.source == "startup")
        // 사용자가 고른 값(repo.model)이 아니라 **실제 적용된** 모델이다.
        #expect(e.model == "claude-opus-5")
    }

    /// 프롬프트 전문은 기록하지 않는다. 길이가 무제한이고 상태 판정에 필요 없다.
    @Test func UserPromptSubmit_은_프롬프트_내용을_남기지_않는다() throws {
        let e = try Self.event(Self.promptSubmitJSON)
        #expect(e.payload == nil)
        #expect(e.ccSessionID == nil)
        #expect(!Self.promptSubmitJSON.contains("prompt"))
    }

    @Test func 모르는_버전은_지원하지_않는다고_답한다() throws {
        let e = try Self.event(#"{"v":99,"ev":"SessionStart","dure_session":"x"}"#)
        #expect(!e.isSupported)
    }

    @Test func 깨진_JSON_은_이벤트가_되지_않는다() {
        #expect(HookEvent(data: Data(#"{"v":1,"ev":"Sessi"#.utf8)) == nil)
    }

    // MARK: - 매핑 (인메모리 DB)

    private func makeDB(agentSession: String? = "fixture-pane") throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo", label: nil, model: nil).insert(db)
            if let s = agentSession {
                try Agent(dureSession: s, repoId: "r1", agentKind: "claude",
                          state: .started, model: nil, startedAt: 0, endedAt: nil).insert(db)
            }
        }
        return q
    }

    @Test func SessionStart_가_cc_session_한_행이_된다() throws {
        let q = try makeDB()
        let e = try Self.event(Self.sessionStartJSON)

        let outcome = try q.write { try SessionBridge.apply(e, in: $0) }
        #expect(outcome == .recorded)

        let rows = try q.read { try CCSession.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].ccSessionId == "cc-aaa")
        #expect(rows[0].dureSession == "fixture-pane")
        #expect(rows[0].transcriptPath == "/Users/x/.claude/projects/p/cc-aaa.jsonl")
        #expect(rows[0].source == "startup")
    }

    /// 부록 A4 의 핵심 — agent : cc_session 은 1:N 이다.
    /// PK 를 dure_session 으로 잡았다면 여기서 앞선 트랜스크립트가 사라진다.
    @Test func clear_는_새_행을_만든다_덮어쓰지_않는다() throws {
        let q = try makeDB()
        let first = try Self.event(Self.sessionStartJSON)
        let second = try Self.event(Self.sessionStartJSON
            .replacingOccurrences(of: "cc-aaa", with: "cc-bbb")
            .replacingOccurrences(of: #""source":"startup""#, with: #""source":"clear""#))

        try q.write { try SessionBridge.apply(first, in: $0) }
        try q.write { try SessionBridge.apply(second, in: $0) }

        let rows = try q.read { try CCSession.order(Column("cc_session_id")).fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.map(\.ccSessionId) == ["cc-aaa", "cc-bbb"])
        #expect(rows.map(\.source) == ["startup", "clear"])
        // 두 행 모두 같은 페인에 달린다. 토큰은 나중에 이 둘을 합산한다.
        #expect(Set(rows.map(\.dureSession)) == ["fixture-pane"])
    }

    /// 같은 레포에 페인 2개를 띄워도 각자 자기 transcript 에 매핑돼야 한다 (Step 4 완료 조건).
    @Test func 같은_레포의_페인_둘이_서로_섞이지_않는다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo", label: nil, model: nil).insert(db)
            for pane in ["pane-A", "pane-B"] {
                try Agent(dureSession: pane, repoId: "r1", agentKind: "claude",
                          state: .started, model: nil, startedAt: 0, endedAt: nil).insert(db)
            }
        }
        let a = try Self.event(Self.sessionStartJSON
            .replacingOccurrences(of: "fixture-pane", with: "pane-A")
            .replacingOccurrences(of: "cc-aaa", with: "cc-A"))
        let b = try Self.event(Self.sessionStartJSON
            .replacingOccurrences(of: "fixture-pane", with: "pane-B")
            .replacingOccurrences(of: "cc-aaa", with: "cc-B"))
        try q.write { try SessionBridge.apply(a, in: $0) }
        try q.write { try SessionBridge.apply(b, in: $0) }

        let rows = try q.read { try CCSession.order(Column("cc_session_id")).fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.dureSession == "pane-A" })?.ccSessionId == "cc-A")
        #expect(rows.first(where: { $0.dureSession == "pane-B" })?.ccSessionId == "cc-B")
    }

    /// 앱을 다시 깐 뒤 남아 있던 이벤트가 들어오는 경우. 외래키로 터지면 안 된다.
    @Test func 모르는_페인의_이벤트는_건너뛴다() throws {
        let q = try makeDB(agentSession: nil)
        let e = try Self.event(Self.sessionStartJSON)
        let outcome = try q.write { try SessionBridge.apply(e, in: $0) }
        #expect(outcome == .unknownAgent)
        #expect(try q.read { try CCSession.fetchCount($0) } == 0)
    }

    @Test func transcript_path_가_없으면_기록하지_않는다() throws {
        let q = try makeDB()
        let e = try Self.event(#"""
        {"v":1,"ev":"SessionStart","dure_session":"fixture-pane","payload":{"session_id":"cc-x"}}
        """#)
        let outcome = try q.write { try SessionBridge.apply(e, in: $0) }
        #expect(outcome == .missingFields)
        #expect(try q.read { try CCSession.fetchCount($0) } == 0)
    }
}
