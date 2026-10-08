import Foundation
import Testing
@testable import Dure

/// 단계 4 — `Stop` 의 `last_assistant_message` 가 배분 결과다 (실측 2026-10-08). shim 은 페이로드를 통째로 저장한다.
@MainActor
struct HookEventTests {

    static func event(_ json: String) throws -> HookEvent {
        try #require(HookEvent(data: Data(json.utf8)))
    }

    @Test func Stop_의_마지막_답을_읽는다() throws {
        let e = try Self.event(#"{"v":1,"ts":"t","ev":"Stop","dure_session":"s","payload":{"last_assistant_message":"다 했다\n두 줄","stop_hook_active":false}}"#)
        #expect(e.lastAssistantMessage == "다 했다\n두 줄")
    }

    @Test func 없으면_nil() throws {
        let e = try Self.event(#"{"v":1,"ts":"t","ev":"UserPromptSubmit","dure_session":"s"}"#)
        #expect(e.lastAssistantMessage == nil)
    }
}
