import Foundation
import GRDB
import Testing
@testable import Dure

/// Step 6 · F4 상태 · F5 알림.
/// 여기서 지키려는 것은 "울리는 것" 보다 **"안 울리는 것"** 이다.
struct AgentStateTests {

    static func event(_ ev: String, payload: String = "{}") throws -> HookEvent {
        let json = #"{"v":1,"ts":"2026-09-02T00:00:00Z","ev":"\#(ev)","agent_kind":"claude","dure_session":"pane","payload":\#(payload)}"#
        return try #require(HookEvent(data: Data(json.utf8)))
    }

    // MARK: - 정상 전이

    @Test func 훅_넷이_상태를_옮긴다() throws {
        #expect(AgentStateMachine.reaction(to: try Self.event("SessionStart"), current: nil).next == .started)
        #expect(AgentStateMachine.reaction(to: try Self.event("UserPromptSubmit"), current: .started).next == .running)
        #expect(AgentStateMachine.reaction(to: try Self.event("Stop"), current: .running).next == .done)

        let permission = try Self.event("Notification", payload: #"{"notification_type":"permission_prompt","message":"파일을 수정할까요?"}"#)
        let r = AgentStateMachine.reaction(to: permission, current: .running)
        #expect(r.next == .waiting)
        #expect(r.alert == .waiting("파일을 수정할까요?"))
    }

    @Test func SessionStart_는_매핑도_함께_기록한다() throws {
        #expect(AgentStateMachine.reaction(to: try Self.event("SessionStart"), current: nil).bridgeSession)
    }

    @Test func Stop_은_트랜스크립트를_읽게_한다() throws {
        let r = AgentStateMachine.reaction(to: try Self.event("Stop"), current: .running)
        #expect(r.ingestTranscript)
        #expect(r.alert == .done)
    }

    // MARK: - 오탐 방지 (이 이슈의 급소)

    /// `idle_prompt` 는 "그냥 60초 놀고 있다" 는 뜻이다. 사람이 할 일이 없다.
    /// 알리면 방치한 세션마다 60초에 한 번씩 뜨고, 사용자는 알림을 꺼버린다.
    /// **상태도 바꾸면 안 된다** — `대기중` 으로 보이는 것 역시 거짓말이다.
    @Test func idle_prompt_는_알리지도_상태를_바꾸지도_않는다() throws {
        // 아래 payload 는 **실제로 받은 것**이다. 세션을 100초 방치했더니 왔다.
        // 문구가 "Claude is waiting for your input" 이라 **진짜 승인 대기와 구별되지 않는다.**
        // 그래서 message 가 아니라 notification_type 으로 걸러야 한다.
        let idle = try Self.event("Notification", payload: #"{"session_id":"f7a19724","transcript_path":"/Users/x/p/f7a19724.jsonl","cwd":"/repo","prompt_id":"177c806f","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#)
        let r = AgentStateMachine.reaction(to: idle, current: .running)
        #expect(r.next == nil)
        #expect(r.alert == nil)
        #expect(r == .ignore)
    }

    /// 문구로 거르면 안 된다는 것을 못박아 둔다.
    /// `idle_prompt` 와 `permission_prompt` 는 같은 문구로도 올 수 있다.
    @Test func 같은_문구라도_종류로_갈린다() throws {
        let text = "Claude is waiting for your input"
        let idle = try Self.event("Notification",
            payload: #"{"notification_type":"idle_prompt","message":"\#(text)"}"#)
        let real = try Self.event("Notification",
            payload: #"{"notification_type":"permission_prompt","message":"\#(text)"}"#)

        #expect(AgentStateMachine.reaction(to: idle, current: .running) == .ignore)
        #expect(AgentStateMachine.reaction(to: real, current: .running).next == .waiting)
    }

    /// 종류를 모르면 알리지 않는다. 모르는 값에 알림을 띄우는 쪽이 위험하다.
    @Test func notification_type_이_없으면_무시한다() throws {
        let bare = try Self.event("Notification", payload: #"{"message":"?"}"#)
        #expect(AgentStateMachine.reaction(to: bare, current: .running) == .ignore)
    }

    /// PTY 가 죽은 뒤 늦게 도착한 이벤트가 상태를 되돌리면 화면이 거짓말을 한다.
    @Test func 죽은_페인은_되살아나지_않는다() throws {
        for ev in ["SessionStart", "UserPromptSubmit", "Stop"] {
            #expect(AgentStateMachine.reaction(to: try Self.event(ev), current: .dead) == .ignore)
        }
        let permission = try Self.event("Notification", payload: #"{"notification_type":"permission_prompt"}"#)
        #expect(AgentStateMachine.reaction(to: permission, current: .dead) == .ignore)
    }

    @Test func 모르는_이벤트는_무시한다() throws {
        #expect(AgentStateMachine.reaction(to: try Self.event("PreToolUse"), current: .running) == .ignore)
    }

    // MARK: - 저장

    @Test func 상태와_종료시각이_DB에_남는다() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Workspace(id: "w1", name: "ws").insert(db)
            try Repo(id: "r1", workspaceId: "w1", path: "/repo", label: nil, model: nil, role: nil).insert(db)
            try Agent(dureSession: "pane", workspaceId: "w1", repoId: "r1", agentKind: "claude",
                      state: .started, model: nil, startedAt: 0, endedAt: nil).insert(db)
        }
        try q.write { db in
            var a = try #require(try Agent.fetchOne(db, key: "pane"))
            a.state = .dead
            a.endedAt = 1_770_000_000
            try a.update(db)
        }
        let saved = try #require(try q.read { try Agent.fetchOne($0, key: "pane") })
        #expect(saved.state == .dead)
        #expect(saved.endedAt == 1_770_000_000)
    }

    @Test func 사람_손이_필요한_상태는_대기중_하나뿐이다() {
        #expect(AgentState.allCases.filter(\.needsAttention) == [.waiting])
    }

    // MARK: - Codex

    static func codexEvent(_ ev: String, payload: String? = nil) throws -> HookEvent {
        let p = payload.map { #","payload":\#($0)"# } ?? ""
        let json = #"{"v":1,"ts":"2026-11-19T00:00:00Z","ev":"\#(ev)","agent_kind":"codex","dure_session":"pane"\#(p)}"#
        return try #require(HookEvent(data: Data(json.utf8)))
    }

    @Test func Codex_승인_요청은_승인_대기와_알림이다() throws {
        let e = try Self.codexEvent("PermissionRequest", payload: #"{"session_id":"s","turn_id":"t","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push --force origin b"}}"#)
        #expect(e.toolCommand == "git push --force origin b")
        let r = AgentStateMachine.reaction(to: e, current: .running)
        #expect(r.next == .waiting)
        #expect(r.alert == .waiting("승인이 필요합니다: git push --force origin b"))
    }

    @Test func Codex_승인_요청_명령이_길면_120자에서_자르고_줄임표를_붙인다() throws {
        let long = String(repeating: "a", count: 200)
        let e = try Self.codexEvent("PermissionRequest", payload: #"{"tool_input":{"command":"\#(long)"}}"#)
        let r = AgentStateMachine.reaction(to: e, current: .running)
        #expect(r.alert == .waiting("승인이 필요합니다: " + String(repeating: "a", count: 120) + "…"))
        let exact = String(repeating: "b", count: 120)
        let e2 = try Self.codexEvent("PermissionRequest", payload: #"{"tool_input":{"command":"\#(exact)"}}"#)
        #expect(AgentStateMachine.reaction(to: e2, current: .running).alert == .waiting("승인이 필요합니다: " + exact))
    }

    @Test func Codex_승인_요청에_명령이_없으면_문구만_알린다() throws {
        let e = try Self.codexEvent("PermissionRequest", payload: #"{"tool_name":"Bash"}"#)
        let r = AgentStateMachine.reaction(to: e, current: .running)
        #expect(r.next == .waiting)
        #expect(r.alert == .waiting("승인이 필요합니다."))
    }

    @Test func 승인_대기_뒤_툴이_끝나면_실행_중으로_돌아간다() throws {
        let r = AgentStateMachine.reaction(to: try Self.codexEvent("PostToolUse"), current: .waiting)
        #expect(r.next == .running)
        #expect(r.alert == nil)
    }

    @Test func 실행_중에_온_PostToolUse_는_상태를_바꾸지_않는다() throws {
        for s: AgentState in [.running, .started, .done] {
            #expect(AgentStateMachine.reaction(to: try Self.codexEvent("PostToolUse"), current: s) == .ignore)
        }
    }

    @Test func 죽은_페인에_온_Codex_이벤트는_무시한다() throws {
        for ev in ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"] {
            #expect(AgentStateMachine.reaction(to: try Self.codexEvent(ev), current: .dead) == .ignore)
        }
    }
}
