// Dure/DureTests/FindingsTests.swift
import Foundation
import GRDB
import Testing
@testable import Dure

struct FindingsTests {

    static func turn(_ id: String, event: String, ts: Int, prompt: String, answer: String? = nil, session: String = "sess-aaaa-1") -> ObsTurn {
        ObsTurn(id: id, unitId: "u1", eventId: event, ccSessionId: session, transcriptPath: "/p", lineNo: ts,
                origin: .terminal, promptKind: .human, ts: ts, prompt: prompt, answerTail: answer)
    }

    static let turns = [turn("t1", event: "e1a2b3c4-aaaa", ts: 100, prompt: "안드로이드 #288 을 iOS 로 옮겨줘"),
                        turn("t2", event: "f9e8d7c6-bbbb", ts: 200, prompt: "빌드 다시 돌려줘", answer: "xcodebuild 가   실패했습니다\n원인은 모듈")]

    static func raw(_ key: String = "vague-build-prompt", group: String = "habit", kind: String = "prompt",
                    severity: Int = 2, confidence: String = "high",
                    evidence: [EvalFinding.Ref] = [.init(event: "f9e8d7c6", quote: "빌드 다시 돌려")]) -> EvalFinding {
        EvalFinding(group: group, kind: kind, key: key, title: "빌드 지시가 짧다", detail: "d", suggestion: "s",
                    applyText: nil, evidence: evidence, severity: severity, confidence: confidence)
    }

    // MARK: - 검증 (리뷰 P1-E)

    @Test func 원문에_있는_인용만_통과한다() {
        let index = EvidenceIndex(turns: Self.turns)
        let (ok, bad) = FindingValidator.validate([
            Self.raw(),
            Self.raw("ws-quote", evidence: [.init(event: "f9e8d7c6", quote: "xcodebuild 가 실패했습니다")]),   // 공백 정규화
            Self.raw("fake-event", evidence: [.init(event: "deadbeef", quote: "빌드 다시 돌려")]),
            Self.raw("fake-quote", evidence: [.init(event: "e1a2b3c4", quote: "이런 말은 없었다")]),
            Self.raw("short-quote", evidence: [.init(event: "e1a2b3c4", quote: "iOS")]),
            Self.raw("bad-enum", group: "everything"),
            Self.raw("bad-kind", kind: "vibes"),
            Self.raw("bad-sev", severity: 99),
            Self.raw("bad-conf", confidence: "maybe"),
            Self.raw("Bad Key"),
            Self.raw("no-evidence", evidence: []),
        ], index: index)
        #expect(ok.map(\.key) == ["vague-build-prompt", "ws-quote"])
        #expect(ok[0].evidence == [Evidence(eventId: "f9e8d7c6-bbbb", sessionId: "sess-aaaa-1", turn: 2, quote: "빌드 다시 돌려", ts: 200)])
        #expect(ok[0].observedAt == 200)
        #expect(Set(bad.map(\.key)) == ["fake-event", "fake-quote", "short-quote", "bad-enum", "bad-kind", "bad-sev",
                                        "bad-conf", "Bad Key", "no-evidence"])
    }

    @Test func 근거_일부만_틀리면_맞는_근거만_남긴다() {
        let (ok, _) = FindingValidator.validate([Self.raw(evidence: [.init(event: "e1a2b3c4", quote: "#288 을 iOS 로"),
                                                                     .init(event: "deadbeef", quote: "x")])],
                                                index: EvidenceIndex(turns: Self.turns))
        #expect(ok.first?.evidence.count == 1 && ok.first?.observedAt == 100)
    }

    /// 최종 리뷰 F5a — 다이제스트가 프롬프트 줄에 붙인 `> ` 를 그대로 복사해 와도 통과한다.
    @Test func 인용_머리의_꺾쇠는_걷는다() {
        #expect(FindingValidator.normalize("> 빌드 다시\n> 돌려") == "빌드 다시 돌려")
        #expect(FindingValidator.normalize(">빌드 다시 돌려") == "빌드 다시 돌려")
        let (ok, _) = FindingValidator.validate([Self.raw(evidence: [.init(event: "e1a2b3c4", quote: "> #288 을 iOS 로")])],
                                                index: EvidenceIndex(turns: Self.turns))
        #expect(ok.count == 1)
    }

    /// 최종 리뷰 F3 — 조율자 턴(다이제스트 3절, O 번호)을 근거로 단 지적도 통과한다.
    @Test func 조율자_턴을_근거로_쓸_수_있다() {
        let orch = [Self.turn("o1", event: "0a0b0c0d-cccc", ts: 50, prompt: "둘 다 로그인 버튼 파랑으로 바꿔", session: "orch-1")]
        let index = EvidenceIndex(turns: Self.turns, orchestratorTurns: orch)
        let (ok, bad) = FindingValidator.validate([Self.raw(evidence: [.init(event: "0a0b0c0d", quote: "로그인 버튼 파랑으로")])],
                                                  index: index)
        #expect(bad.isEmpty)
        #expect(ok.first?.evidence == [Evidence(eventId: "0a0b0c0d-cccc", sessionId: "orch-1", turn: 1, quote: "로그인 버튼 파랑으로",
                                                ts: 50, label: "O1")])
        #expect(ok.first?.evidence.first?.display == "O1")
        #expect(index["f9e8d7c6"]?.turn == 2 && index["f9e8d7c6"]?.label == nil)     // 레포 턴 번호는 그대로
    }

    @Test func 옛_근거_JSON_도_읽힌다() throws {
        let e = try JSONDecoder().decode([Evidence].self, from: Data(#"[{"eventId":"e","sessionId":"s","turn":3,"quote":"q","ts":1}]"#.utf8))
        #expect(e.first?.display == "T3")
    }

    /// 최종 리뷰 F2 — 한 실행에서 같은 key 가 두 번 나오면 하나로 합친다(관찰 횟수가 부풀지 않게).
    @Test func 한_실행의_같은_key_는_하나로_합친다() throws {
        var second = Self.raw(severity: 3, evidence: [.init(event: "e1a2b3c4", quote: "#288 을 iOS 로"),
                                                      .init(event: "f9e8d7c6", quote: "빌드 다시 돌려")])
        second.title = "다른 제목"
        let (ok, _) = FindingValidator.validate([Self.raw(), second], index: EvidenceIndex(turns: Self.turns))
        #expect(ok.count == 1)
        #expect(ok[0].title == "빌드 지시가 짧다" && ok[0].severity == 3 && ok[0].observedAt == 200)
        #expect(ok[0].evidence.map(\.eventId) == ["f9e8d7c6-bbbb", "e1a2b3c4-aaaa"])
        try evaluate("u1", ok, at: 300)
        let item = try db.read { try #require(try BacklogItem.fetchOne($0, key: "vague-build-prompt")) }
        #expect(item.observedCount == 1)
        #expect(try db.read { try Finding.fetchCount($0) } == 1)
    }

    // MARK: - 백로그

    let db: DatabaseQueue
    init() throws {
        db = try Fx.memoryDB()
        try db.write { db in
            for id in ["u1", "u2"] {
                try WorkUnit(id: id, unitKey: id, baseKey: id, kind: .issueBranch, firstTs: 0, lastTs: 0).insert(db)
            }
        }
    }

    func validated(_ key: String = "kkk", group: String = "dure", severity: Int = 2, observedAt: Int = 100) -> ValidatedFinding {
        ValidatedFinding(group: group, kind: "friction", key: key, title: "제목", detail: "설명", suggestion: "제안",
                         applyText: nil, evidence: [Evidence(eventId: "e", sessionId: "s", turn: 1, quote: "인용 인용", ts: observedAt)],
                         severity: severity, confidence: "high", observedAt: observedAt)
    }

    /// 실행을 done 으로 만든 뒤 apply — 실제 EvaluationJob 순서와 같다.
    @discardableResult
    func evaluate(_ unit: String, _ fs: [ValidatedFinding], at now: Int) throws -> BacklogStore.Outcome {
        try db.write { db in
            let run = EvaluationRun(unitId: unit, trigger: .manual, status: .done, createdAt: now, finishedAt: now)
            try run.insert(db)
            return try BacklogStore.apply(fs, unitID: unit, runID: run.id, now: now, in: db)
        }
    }

    func item(_ key: String = "kkk") throws -> BacklogItem? { try db.read { try BacklogItem.fetchOne($0, key: key) } }

    @Test func 새_지적은_새_항목() throws {
        #expect(try evaluate("u1", [validated()], at: 10) == .init(new: 1, reopened: 0, repeated: 0))
        let i = try #require(try item())
        #expect(i.bucket == .dure && i.state == .open && i.observedCount == 1 && i.unitCount == 1 && i.maxSeverity == 2)
        #expect(i.firstSeen == 100 && i.lastSeen == 100)          // 관찰 시각 = 근거 턴 시각
    }

    @Test func 다른_작업에서_같은_key_면_합친다() throws {
        try evaluate("u1", [validated(severity: 1, observedAt: 100)], at: 10)
        #expect(try evaluate("u2", [validated(severity: 3, observedAt: 300)], at: 20).repeated == 1)
        let i = try #require(try item())
        #expect(i.observedCount == 2 && i.unitCount == 2 && i.maxSeverity == 3 && i.firstSeen == 100 && i.lastSeen == 300)
    }

    /// Review Focus 3 — 다시 평가해도 횟수가 늘지 않고, 이력은 남는다.
    @Test func 같은_단위를_다시_평가해도_횟수가_늘지_않는다() throws {
        try evaluate("u1", [validated()], at: 10)
        try evaluate("u1", [validated()], at: 11)
        #expect(try item()?.observedCount == 1)
        #expect(try db.read { try Finding.fetchCount($0) } == 2)
    }

    @Test func 다시_평가에서_사라진_지적은_숫자가_0_이_된다() throws {
        try evaluate("u1", [validated("gone"), validated("stay")], at: 10)
        try evaluate("u1", [validated("stay")], at: 11)
        #expect(try item("gone")?.observedCount == 0)
        #expect(try item("stay")?.observedCount == 1)
    }

    /// 리뷰 P1-F — 해결 전 옛 근거를 다시 평가한 것은 재발이 아니다. 해결 뒤에 생긴 근거만 재발이다.
    @Test func 같은_근거를_다시_평가해도_재발이_아니다() throws {
        try evaluate("u1", [validated(observedAt: 100)], at: 10)
        try db.write { try BacklogStore.setState("kkk", .resolved, linkedIssue: nil, now: 500, in: $0) }
        #expect(try evaluate("u1", [validated(observedAt: 100)], at: 600).reopened == 0)
        #expect(try item()?.state == .resolved)
        #expect(try evaluate("u2", [validated(observedAt: 700)], at: 800).reopened == 1)
        #expect(try item()?.state == .reopened)
    }

    @Test func 무시는_숫자만_는다() throws {
        try evaluate("u1", [validated()], at: 10)
        try db.write { try BacklogStore.setState("kkk", .dismissed, linkedIssue: nil, now: 20, in: $0) }
        try evaluate("u2", [validated(observedAt: 900)], at: 30)
        let i = try #require(try item())
        #expect(i.state == .dismissed && i.observedCount == 2)
    }

    @Test func 피드백을_센다() throws {
        try evaluate("u1", [validated()], at: 10)
        try evaluate("u2", [validated()], at: 11)
        let ids = try db.read { try Finding.fetchAll($0).map(\.id) }
        try db.write { db in
            try BacklogStore.setFeedback(findingID: ids[0], .useful, now: 12, in: db)
            try BacklogStore.setFeedback(findingID: ids[1], .falsePositive, now: 13, in: db)
        }
        let i = try #require(try item())
        #expect(i.usefulCount == 1 && i.falsePositiveCount == 1)
    }

    @Test func 정렬은_작업_수_x_심각도_오탐이_많으면_아래() {
        func i(_ k: String, units: Int, sev: Int, last: Int, fp: Int = 0) -> BacklogItem {
            BacklogItem(key: k, bucket: .dure, grp: "dure", kind: "x", title: k, detail: "", state: .open,
                        observedCount: 5, unitCount: units, maxSeverity: sev, lastSeen: last, falsePositiveCount: fp)
        }
        let r = BacklogRules.ranked([i("one-unit", units: 1, sev: 3, last: 9), i("five-units", units: 5, sev: 1, last: 1),
                                     i("tie-recent", units: 1, sev: 3, last: 10), i("noisy", units: 9, sev: 3, last: 99, fp: 3)])
        #expect(r.map(\.key) == ["five-units", "tie-recent", "one-unit", "noisy"])
    }

    @Test func 버킷과_key_형식() {
        #expect(BacklogRules.bucket(group: "tooling") == .habit && BacklogRules.bucket(group: "dure") == .dure)
        #expect(BacklogRules.isValidKey("dispatch-completion") && !BacklogRules.isValidKey("ab") && !BacklogRules.isValidKey("한글"))
    }
}
