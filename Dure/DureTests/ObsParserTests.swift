// Dure/DureTests/ObsParserTests.swift
import Foundation
import Testing
@testable import Dure

struct ObsParserTests {

    func one(_ line: String) throws -> ObsParser.Event {
        let events = try #require(ObsParser.parse(Fx.data(line)))
        #expect(events.count == 1)
        return try #require(events.first)
    }

    @Test func 사람_프롬프트는_턴_시작이고_이벤트_ID_가_있다() throws {
        guard case let .turnStart(ctx, prompt, kind, mode) = try one(Fx.human("iOS 로 옮겨줘", uuid: "ev-1")) else {
            Issue.record("턴 시작이 아님"); return
        }
        #expect(prompt == "iOS 로 옮겨줘" && kind == .human && mode == "default")
        #expect(ctx.eventId == "ev-1")
        #expect(ctx.sessionId == "s1" && ctx.cwd == "/r/ios" && ctx.gitBranch == "feat/#52/x")
        #expect(ctx.ts == 1_791_594_000)
    }

    @Test func claude_p_는_sdk_다() throws {
        guard case let .turnStart(_, _, kind, _) = try one(Fx.human("x", source: "sdk")) else { Issue.record(""); return }
        #expect(kind == .sdk)
    }

    @Test func 다른_세션의_메시지는_peer_턴이다() throws {
        guard case let .turnStart(_, prompt, kind, _) = try one(Fx.peer("[두레] 조율자 배분 #7")) else { Issue.record(""); return }
        #expect(kind == .peer && prompt == "[두레] 조율자 배분 #7")
    }

    // MARK: - 이슈 #32 입력 분류

    @Test(arguments: [
        ("<task-notification> <task-id>a1</task-id>", PromptKind.notice),
        ("<bash-input>git add .</bash-input>", .shell),
        ("<bash-stdout>(Bash completed with no output)</bash-stdout><bash-stderr></bash-stderr>", .shell),
        ("<command-message>pr-draft</command-message>\n<command-name>/pr-draft</command-name>", .command),
        ("<command-name>/superpowers:brainstorming</command-name>", .command),
        ("<command-name>/clear</command-name>\n<command-message>clear</command-message>", .builtin),
        ("  <command-name>/compact</command-name>", .builtin),
        ("진행", .human),
    ])
    func 입력_분류(_ text: String, _ kind: PromptKind) throws {
        guard case let .turnStart(_, _, k, _) = try one(Fx.human(text)) else { Issue.record("턴 시작이 아님"); return }
        #expect(k == kind)
    }

    @Test func 사람_요청으로_세는_kind() {
        #expect(PromptKind.allCases.filter(\.countsAsHuman) == [.human, .command])
        #expect(PromptKind.humanSQLList == "('human','command')")
    }

    @Test func 스킬_본문_같은_메타는_무시한다() throws {
        #expect(try one(Fx.meta("Base directory for this skill: /x")) == .ignored)
    }

    @Test func 툴_호출과_사용량이_한_줄에서_나온다() throws {
        let events = try #require(ObsParser.parse(Fx.data(Fx.toolUse("tu1", name: "Read", input: ["file_path": "/r/a.swift"]))))
        #expect(events.count == 2)
        guard case let .assistant(_, text, mid, _, usage) = events[0] else { Issue.record(""); return }
        #expect(text == nil && mid == "msg_T")
        #expect(usage == .init(input: 10, output: 20, cacheCreation: 5, cacheRead: 1000))
        #expect(usage.headline == 35)
        guard case let .toolUse(_, id, name, target) = events[1] else { Issue.record(""); return }
        #expect(id == "tu1" && name == "Read" && target == "/r/a.swift")
    }

    @Test(arguments: [
        ("Bash", ["command": "xcodebuild -scheme Bookiibookii build"] as [String: Any], "xcodebuild -scheme Bookiibookii build"),
        ("Grep", ["pattern": "TODO"], "TODO"),
        ("Skill", ["skill": "superpowers:brainstorming"], "superpowers:brainstorming"),
        ("Agent", ["subagent_type": "Explore", "description": "찾기"], "Explore"),
        ("Edit", ["file_path": "/r/b.kt"], "/r/b.kt"),
        ("mcp__dure__dispatch", ["repo": "moamap-iOS", "instruction": "x"], "moamap-iOS"),
        ("mcp__figma__get_design_context", [:], nil),
    ] as [(String, [String: Any], String?)])
    func 툴_대상(_ name: String, _ input: [String: Any], _ expected: String?) {
        #expect(ObsParser.target(name: name, input: input) == expected)
    }

    @Test func Bash_명령은_120자로_자른다() {
        #expect(ObsParser.target(name: "Bash", input: ["command": String(repeating: "a", count: 300)])?.count == 120)
    }

    @Test func 툴_결과와_거부() throws {
        guard case let .toolResult(_, id, isError, head, denied) =
                try one(Fx.toolResult("tu1", isError: true, content: "error: no such file\n자세히", denied: true)) else {
            Issue.record(""); return
        }
        #expect(id == "tu1" && isError && denied && head == "error: no such file")
    }

    @Test func 답_텍스트() throws {
        guard case let .assistant(_, text, mid, model, _) = try one(Fx.text("다 옮겼습니다")) else { Issue.record(""); return }
        #expect(text == "다 옮겼습니다" && mid == "msg_A" && model == "claude-opus-5-5")
    }

    @Test func 턴_길이_중단_압축() throws {
        #expect(try one(Fx.duration(76767)) == .turnDuration(ms: 76767))
        #expect(try one(Fx.interrupted()) == .interrupted)
        #expect(try one(Fx.compact()) == .compacted)
    }

    /// 새 레코드는 자주 생긴다 — 깨진 줄과 구별해 따로 센다(리뷰 P1-I).
    @Test func 아는_무시_type_모르는_type_깨진_줄() throws {
        #expect(try one(#"{"type":"file-history-snapshot","x":1}"#) == .ignored)
        #expect(try one(#"{"type":"brand-new-record","x":1}"#) == .unknownType("brand-new-record"))
        #expect(ObsParser.parse(Fx.data("{not json")) == nil)
        #expect(ObsParser.parse(Fx.data(#"{"type":"user","message":{"content":"x"}}"#)) == nil)
    }

    @Test func 서브에이전트의_사람_줄은_턴이_아니다() throws {
        var o = try #require(try JSONSerialization.jsonObject(with: Fx.data(Fx.human("x"))) as? [String: Any])
        o["isSidechain"] = true
        #expect(try one(Fx.json(o)) == .ignored)
    }

    @Test func 서브에이전트의_사용량과_툴은_사이드체인으로_표시된다() throws {
        let events = try #require(ObsParser.parse(Fx.data(Fx.toolUse("t9", name: "Read", input: [:], sidechain: true))))
        guard case let .assistant(ctx, _, _, _, _) = events[0] else { Issue.record(""); return }
        #expect(ctx.isSidechain)
    }

    @Test func 시각() {
        #expect(ObsParser.epoch("2026-10-10T01:00:00.000Z") == 1_791_594_000)
        #expect(ObsParser.epoch("2026-10-10T01:00:00Z") == 1_791_594_000)
        #expect(ObsParser.epoch("어제") == nil)
    }
}
