// Dure/DureTests/DigestTests.swift
import Foundation
import Testing
@testable import Dure

struct DigestTests {

    static func tool(_ name: String, _ target: String?, start: Int = 0, result: Int? = 1, error: String? = nil,
                     denied: Bool = false, turn: String = "t1") -> ObsTool {
        ObsTool(turnId: turn, transcriptPath: "/p", toolUseId: UUID().uuidString, name: name, target: target,
                startedTs: start, resultTs: result, isError: error != nil, errorHead: error, denied: denied)
    }

    @Test func 원인_미확인_지연은_빠른_툴의_10초_초과() {
        #expect(Signals.isUnexplainedDelay(Self.tool("Read", "/x/a.kt", start: 0, result: 25)))
        #expect(!Signals.isUnexplainedDelay(Self.tool("Read", "/x/a.kt", start: 0, result: 3)))
        #expect(!Signals.isUnexplainedDelay(Self.tool("Read", "/x/a.kt", start: 0, result: nil)))
        #expect(!Signals.isUnexplainedDelay(Self.tool("WebFetch", "https://x", start: 0, result: 60)))   // 네트워크
        #expect(!Signals.isUnexplainedDelay(Self.tool("AskUserQuestion", nil, start: 0, result: 120)))   // 사람의 답을 기다린다
        #expect(!Signals.isUnexplainedDelay(Self.tool("ExitPlanMode", nil, start: 0, result: 120)))
        #expect(!Signals.isUnexplainedDelay(Self.tool("Bash", "xcodebuild -scheme X build", start: 0, result: 90)))
        #expect(Signals.isUnexplainedDelay(Self.tool("Bash", "git -C /r/ios status", start: 0, result: 30)))
    }

    /// 리뷰 P1-G — 지연은 라벨로만 묶는다. allow 규칙 모양(`Bash(git -C *)`)을 만들지 않는다.
    @Test func 지연은_라벨로만_묶고_allow_규칙을_만들지_않는다() {
        let d = Signals.delays([Self.tool("Bash", "git -C /r/ios status", start: 0, result: 30),
                                Self.tool("Bash", "git -C /r/android log", start: 0, result: 20)])
        #expect(d == [Signals.Delay(label: "Bash(git)", count: 2, seconds: 50)])
        #expect(!d.contains { $0.label.contains("*") })
    }

    /// 실제 승인 프롬프트는 같은 세션에서 그 시각 직전 턴에 붙는다 — 세션 전체를 작업마다 중복으로 세지 않는다.
    @Test func 실제_승인_프롬프트는_시각으로_턴에_귀속() {
        let turns = [Self.turn("a", ts: 100, prompt: "1"), Self.turn("b", ts: 200, prompt: "2"),
                     Self.turn("c", ts: 150, prompt: "3", session: "other-session")]
        let perms = [ObsPermission(ccSessionId: "aaaaaaaa-1111", ts: 120), ObsPermission(ccSessionId: "aaaaaaaa-1111", ts: 250),
                     ObsPermission(ccSessionId: "aaaaaaaa-1111", ts: 50)]       // 첫 턴 이전 → 어디에도 안 붙는다
        #expect(Signals.permissionsByTurn(turns: turns, permissions: perms) == ["a": 1, "b": 1])
    }

    @Test func 반복_읽기_실패_스킬_요약() {
        let reads = Array(repeating: Self.tool("Read", "/r/a.swift"), count: 4) + Array(repeating: Self.tool("Read", "/r/b.swift"), count: 3)
        #expect(Signals.repeatedReads(reads) == [Signals.Count(label: "/r/a.swift", count: 4)])
        let fails = [Self.tool("Bash", "xcodebuild build", error: "error: no such module 'Foo'"),
                     Self.tool("Bash", "xcodebuild build", error: "error: no such module 'Foo'"),
                     Self.tool("Bash", "rm -rf x", error: "denied", denied: true)]
        #expect(Signals.failures(fails) == [Signals.Failure(tool: "Bash", target: "xcodebuild build", error: "error: no such module 'Foo'", count: 2)])
        let mixed = [Self.tool("Skill", "superpowers:brainstorming"), Self.tool("mcp__figma__get_design_context", nil),
                     Self.tool("Read", "/a"), Self.tool("Read", "/b"), Self.tool("Bash", "xcodebuild build")]
        #expect(Signals.skillsAndMCP(mixed) == [Signals.Count(label: "mcp:figma", count: 1),
                                                Signals.Count(label: "skill:superpowers:brainstorming", count: 1)])
        #expect(Signals.summary(mixed) == "Read×2 · Skill(superpowers:brainstorming)×1 · mcp:figma×1 · Bash(xcodebuild)×1")
    }

    static func turn(_ id: String, ts: Int, prompt: String, session: String = "aaaaaaaa-1111",
                     origin: TurnOrigin = .terminal, kind: PromptKind = .human) -> ObsTurn {
        ObsTurn(id: id, unitId: "u", eventId: "ev\(id)-0000-1111", ccSessionId: session, transcriptPath: "/p/\(session).jsonl",
                lineNo: ts, origin: origin, promptKind: kind, ts: ts, prompt: prompt, durationMs: 61_000, answerTail: "다 했습니다")
    }

    static var unit: WorkUnit {
        WorkUnit(unitKey: "k", baseKey: "k", kind: .issueBranch, repoRoot: "/r/moamap-iOS", branch: "feat/#52/splash",
                 issueNo: 52, githubRepo: "Moa-Map/moamap-iOS", prNumber: 53, prUrl: "https://github.com/x/53",
                 mergedAt: 1_791_600_000, firstTs: 1_791_594_000, lastTs: 1_791_597_600, humanTurns: 1, peerTurns: 1)
    }

    static let utc = TimeZone(identifier: "UTC")!

    @Test func 다이제스트에_메타_턴_신호_참조() {
        let turns = [Self.turn("t1", ts: 1_791_594_000, prompt: "안드로이드 #288 을 iOS 로 옮겨줘"),
                     Self.turn("t2", ts: 1_791_595_000, prompt: "[두레] 배분 #7", session: "bbbbbbbb-2222",
                               origin: .dureRepo, kind: .peer)]
        let tools = [Self.tool("Read", "/r/a.swift", turn: "t1"),
                     Self.tool("Bash", "git status", start: 1_791_595_001, result: 1_791_595_031, turn: "t2")]
        let s = DigestBuilder.render(DigestInput(
            unit: Self.unit, turns: turns, tools: tools,
            permissions: [ObsPermission(ccSessionId: "bbbbbbbb-2222", ts: 1_791_595_010)],
            diffStat: "4 files changed, 120 insertions(+), 8 deletions(-)",
            references: ["/r/moamap-iOS/CLAUDE.md", "/p/aaaaaaaa-1111.jsonl"],
            missingTranscripts: ["/p/aaaaaaaa-1111.jsonl"], timeZone: Self.utc))
        #expect(s.contains("moamap-iOS · #52"))
        #expect(s.contains("자동 추정 묶음"))
        #expect(s.contains("PR #53") && s.contains("4 files changed"))
        #expect(s.contains("### T1 · 10-10 01:00 · 터미널 · `aaaaaaaa` · e:evt1-000"))
        #expect(s.contains("> 안드로이드 #288 을 iOS 로 옮겨줘"))
        #expect(s.contains("### T2 · 10-10 01:16 · 두레 레포 페인 · `bbbbbbbb` · e:evt2-000 · peer"))
        #expect(s.contains("실제 승인 프롬프트 1"))
        #expect(s.contains("원인 미확인 지연"))
        #expect(s.contains("`Bash(git)` 1회 · 30초"))
        #expect(s.contains("- 답 끝: 다 했습니다"))
        #expect(s.contains("/p/aaaaaaaa-1111.jsonl (원본 삭제됨)"))
    }

    @Test func 조율자_대화와_배분() {
        let s = DigestBuilder.render(DigestInput(
            unit: Self.unit, turns: [Self.turn("t1", ts: 1_791_594_000, prompt: "a")], tools: [],
            orchestratorTurns: [Self.turn("o1", ts: 1_791_593_000, prompt: "둘 다 로그인 버튼 파랑으로", origin: .dureOrchestrator)],
            dispatches: [DigestDispatch(seq: 7, repoName: "moamap-iOS", title: nil, instruction: "버튼 색을 #1E6BFF 로",
                                        state: "done", createdAt: 1_791_593_100, deliveredAt: 1_791_593_400,
                                        doneAt: 1_791_594_000, result: "바꿨습니다")],
            timeZone: Self.utc))
        #expect(s.contains("## 3. 조율자 대화 · 배분"))
        #expect(s.contains("둘 다 로그인 버튼 파랑으로"))
        #expect(s.contains("- O1 · 10-10 00:43 · 조율자 · e:evo1-000 — 둘 다 로그인 버튼 파랑으로"))   // 최종 리뷰 F3 — 인용 가능
        #expect(s.contains("배분 #7 → moamap-iOS · done · 큐 대기 300초"))
    }

    @Test func 한도를_넘으면_프롬프트를_줄이고_가운데_턴을_생략한다() {
        let long = String(repeating: "가", count: 1400)
        let turns = (0..<400).map { Self.turn("t\($0)", ts: 1_791_594_000 + $0 * 60, prompt: long) }
        let s = DigestBuilder.render(DigestInput(unit: Self.unit, turns: turns, tools: [], timeZone: Self.utc))
        #expect(s.count <= DigestBuilder.charLimit)
        #expect(s.contains("### T1 ") && s.contains("### T400 "))
        #expect(s.contains("T51~T350 생략 (300턴)"))
        #expect(s.contains("자 생략)"))          // 잘라낸 곳을 밝힌다
    }

    /// 응답 대기(waiting) 배분의 result 는 완료 요약이 아니라 에이전트의 마지막 응답이다 — "결과" 로 읽히면 안 된다.
    @Test func 응답_대기_배분은_마지막_응답으로_표시() {
        func render(_ state: String) -> String {
            DigestBuilder.render(DigestInput(
                unit: Self.unit, turns: [Self.turn("t1", ts: 1_791_594_000, prompt: "a")], tools: [],
                dispatches: [DigestDispatch(seq: 8, repoName: "moamap-iOS", title: nil, instruction: "x",
                                            state: state, createdAt: 1_791_593_100, result: "어떤 색으로 할까요?")],
                timeZone: Self.utc))
        }
        #expect(render("waiting").contains("  - 마지막 응답(응답 대기): 어떤 색으로 할까요?"))
        #expect(render("done").contains("  - 결과: 어떤 색으로 할까요?"))
        #expect(render("failed").contains("  - 기록: 어떤 색으로 할까요?"))
    }

    @Test func 토큰_절() {
        var t1 = Self.turn("t1", ts: 1_791_594_000, prompt: "a")
        t1.tokensInput = 5000; t1.model = "claude-opus-5-5"
        var i = DigestInput(unit: Self.unit, turns: [t1], tools: [], timeZone: Self.utc)
        i.tokens = TokenAccounting.Breakdown(repo: 5000, subagent: 1000, orchestrator: 1500, sessionStart: 800, cacheRead: 90000,
                                             turns: 2, linesChanged: 100)
        i.baseline = TokenAccounting.Baseline(samples: 4, perTurn: 2500, perLine: 40)
        let s = DigestBuilder.render(i)
        #expect(s.contains("## 5. 토큰"))
        #expect(s.contains("합계 7500 = 레포 작업 5000 · 서브에이전트 1000 · 조율자 몫 1500 (20%)"))
        #expect(s.contains("세션 고정비(세션마다 첫 턴의 캐시 생성) 800"))
        #expect(s.contains("턴당 3750 · 변경 줄당 75"))
        #expect(s.contains("터미널 전용 이슈 작업 4개 중앙값): 턴당 2500 · 변경 줄당 40 → 이번 작업 턴당 1.5배"))
        #expect(s.contains("비싼 턴: T1 5000") && s.contains("모델별: claude-opus-5-5 5000"))
        i.baseline = TokenAccounting.Baseline(samples: 2, perTurn: 100, perLine: nil)
        #expect(DigestBuilder.render(i).contains("터미널 전용 이슈 작업이 2개뿐이라 판단 보류"))
    }
}
