// Dure/Dure/Observer/Findings.swift
import Foundation
import GRDB

/// 평가자의 구조화 출력 한 줄. **믿지 않는다** — `FindingValidator` 를 통과한 것만 쓴다(리뷰 P1-E).
nonisolated struct EvalFinding: Codable, Equatable, Sendable {
    struct Ref: Codable, Equatable, Sendable {
        var event: String
        var quote: String
    }
    var group: String
    var kind: String
    var key: String
    var title: String
    var detail: String
    var suggestion: String?
    var applyText: String?
    var evidence: [Ref]
    var severity: Int
    var confidence: String

    enum CodingKeys: String, CodingKey {
        case group, kind, key, title, detail, suggestion, evidence, severity, confidence
        case applyText = "apply_text"
    }
}

/// 원문과 대조해 확인한 근거. 저장되는 것은 전체 이벤트 ID — T번호는 화면용이다(늦게 온 기록으로 바뀔 수 있다).
nonisolated struct Evidence: Codable, Equatable, Sendable {
    var eventId: String
    var sessionId: String
    var turn: Int
    var quote: String
    var ts: Int
    /// 조율자 턴이면 `O<n>`. 레포 턴은 nil 이고 `T<turn>` 으로 보인다 — 옛 기록(필드 없음)도 그대로 읽힌다.
    var label: String? = nil

    var display: String { label ?? "T\(turn)" }
}

nonisolated struct ValidatedFinding: Equatable, Sendable {
    var group: String
    var kind: String
    var key: String
    var title: String
    var detail: String
    var suggestion: String?
    var applyText: String?
    var evidence: [Evidence]
    var severity: Int
    var confidence: String
    /// 근거 턴 시각의 최댓값.
    var observedAt: Int
}

/// 이 스냅숏의 턴들. 다이제스트의 `e:` 앞 8자로 찾는다.
/// 조율자 턴도 넣는다 — 다이제스트 3절에 `e:` 를 달아 보여주므로, 넣지 않으면 그 인용이 전부 "근거 없음" 으로 버려진다.
nonisolated struct EvidenceIndex: Sendable {
    struct Entry: Sendable {
        var eventId: String; var sessionId: String; var turn: Int; var ts: Int; var text: String
        var label: String? = nil
    }
    private(set) var entries: [String: Entry] = [:]

    /// 번호는 `DigestBuilder` 와 같은 정렬로 매긴다 — 레포 턴 T1…, 조율자 턴 O1….
    init(turns: [ObsTurn], orchestratorTurns: [ObsTurn] = []) {
        for (i, t) in DigestBuilder.ordered(turns).enumerated() { add(t, turn: i + 1, label: nil) }
        for (i, t) in DigestBuilder.ordered(orchestratorTurns).enumerated() { add(t, turn: i + 1, label: "O\(i + 1)") }
    }

    private mutating func add(_ t: ObsTurn, turn: Int, label: String?) {
        let k = DigestBuilder.shortEvent(t.eventId)
        guard entries[k] == nil else { return }     // 앞 8자 충돌은 드물다 — 먼저 온 것(레포 턴)을 쓴다
        entries[k] = Entry(eventId: t.eventId, sessionId: t.ccSessionId, turn: turn, ts: t.ts,
                           text: t.prompt + "\n" + (t.answerTail ?? ""), label: label)
    }

    subscript(_ short: String) -> Entry? { entries[String(short.prefix(8))] }
}

nonisolated enum FindingValidator {

    static let groups: Set<String> = ["dure", "habit", "tooling"]
    static let kinds: Set<String> = ["missing_feature", "friction", "works_well", "prompt", "workflow", "permission",
                                     "claude_md", "skill", "mcp", "cost"]
    static let minQuote = 6

    struct Rejection: Equatable, Sendable { var key: String; var reason: String }

    /// 공백을 하나로, 앞뒤 따옴표 · 말줄임을 걷어낸다 — 모델이 인용을 다듬는 정도는 봐준다.
    /// 줄 머리의 `>` 도 걷는다 — 다이제스트가 프롬프트 줄마다 `> ` 를 붙이므로 그대로 복사한 인용에 섞여 온다.
    static func normalize(_ s: String) -> String {
        let unquoted = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            let l = line.drop(while: { $0 == " " || $0 == "\t" })
            return l.first == ">" ? l.dropFirst() : line
        }.joined(separator: "\n")
        var t = unquoted.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let strip: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "…"]
        while let f = t.first, strip.contains(f) { t.removeFirst() }
        while let l = t.last, strip.contains(l) { t.removeLast() }
        if t.hasSuffix("...") { t.removeLast(3) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func validate(_ findings: [EvalFinding], index: EvidenceIndex) -> (accepted: [ValidatedFinding], rejected: [Rejection]) {
        var ok: [ValidatedFinding] = [], bad: [Rejection] = []
        var at: [String: Int] = [:]     // key → ok 의 자리
        for f in findings {
            guard groups.contains(f.group), kinds.contains(f.kind), (1...3).contains(f.severity),
                  f.confidence == "high" || f.confidence == "low", BacklogRules.isValidKey(f.key),
                  !f.title.trimmingCharacters(in: .whitespaces).isEmpty else {
                bad.append(Rejection(key: f.key, reason: "형식")); continue
            }
            let evidence = f.evidence.compactMap { ref -> Evidence? in
                guard let e = index[ref.event] else { return nil }
                let q = normalize(ref.quote)
                guard q.count >= minQuote, normalize(e.text).contains(q) else { return nil }
                return Evidence(eventId: e.eventId, sessionId: e.sessionId, turn: e.turn, quote: q, ts: e.ts, label: e.label)
            }
            guard let observed = evidence.map(\.ts).max() else { bad.append(Rejection(key: f.key, reason: "근거 없음")); continue }
            // 한 실행 안의 같은 key 는 한 지적으로 합친다 — 따로 두면 finding 행이 둘이 돼 관찰 횟수가 영구히 부푼다(최종 리뷰 F2).
            // 글은 처음 것을, 근거는 합집합(이벤트 기준), 심각도 · 관찰 시각은 큰 쪽.
            if let i = at[f.key] {
                var m = ok[i]
                for e in evidence where !m.evidence.contains(where: { $0.eventId == e.eventId }) { m.evidence.append(e) }
                m.severity = max(m.severity, f.severity)
                m.observedAt = max(m.observedAt, observed)
                ok[i] = m
                continue
            }
            at[f.key] = ok.count
            ok.append(ValidatedFinding(group: f.group, kind: f.kind, key: f.key, title: String(f.title.prefix(80)),
                                       detail: f.detail, suggestion: f.suggestion, applyText: f.applyText,
                                       evidence: evidence, severity: f.severity, confidence: f.confidence, observedAt: observed))
        }
        return (ok, bad)
    }
}

nonisolated enum BacklogRules {
    static func bucket(group: String) -> BacklogBucket { group == "dure" ? .dure : .habit }
    static func isOpen(_ s: BacklogState) -> Bool { s == .open || s == .issued || s == .reopened }
    static func isValidKey(_ k: String) -> Bool { k.range(of: "^[a-z0-9-]{3,60}$", options: .regularExpression) != nil }

    /// 작업 수 × 심각도 → 최근. 오탐이 유용보다 많은 항목은 맨 아래 — 감시자가 틀리는 영역을 위로 올리지 않는다.
    static func ranked(_ items: [BacklogItem]) -> [BacklogItem] {
        items.sorted { a, b in
            let na = a.falsePositiveCount > a.usefulCount, nb = b.falsePositiveCount > b.usefulCount
            if na != nb { return !na }
            return (a.unitCount * a.maxSeverity, a.lastSeen ?? 0) > (b.unitCount * b.maxSeverity, b.lastSeen ?? 0)
        }
    }
}

nonisolated enum BacklogStore {

    struct Outcome: Equatable, Sendable {
        var new = 0, reopened = 0, repeated = 0
    }

    static func apply(_ findings: [ValidatedFinding], unitID: String, runID: String, now: Int, in db: Database) throws -> Outcome {
        // 이 단위의 이전 실행에서 나온 key 도 다시 센다 — 최신 실행이 바뀌었다.
        var touched = Set(try String.fetchAll(db, sql: "SELECT DISTINCT backlog_key FROM finding WHERE unit_id = ?", arguments: [unitID]))
        var out = Outcome()
        var seen: Set<String> = []
        for f in findings {
            if var item = try BacklogItem.fetchOne(db, key: f.key) {
                if !seen.contains(f.key) {
                    if item.state == .resolved, let r = item.resolvedAt, f.observedAt > r {
                        item.state = .reopened
                        out.reopened += 1
                    } else {
                        out.repeated += 1
                    }
                }
                item.title = f.title
                item.detail = f.detail
                item.kind = f.kind
                if let s = f.suggestion { item.suggestion = s }
                if let a = f.applyText { item.applyText = a }
                try item.update(db)
            } else {
                try BacklogItem(key: f.key, bucket: BacklogRules.bucket(group: f.group), grp: f.group, kind: f.kind,
                                title: f.title, detail: f.detail, suggestion: f.suggestion, applyText: f.applyText,
                                state: .open).insert(db)
                out.new += 1
            }
            try Finding(runId: runID, unitId: unitID, backlogKey: f.key, grp: f.group, kind: f.kind, title: f.title,
                        detail: f.detail, suggestion: f.suggestion, applyText: f.applyText,
                        evidence: String(decoding: try JSONEncoder().encode(f.evidence), as: UTF8.self),
                        observedAt: f.observedAt, severity: f.severity, confidence: f.confidence, createdAt: now).insert(db)
            seen.insert(f.key)
            touched.insert(f.key)
        }
        for key in touched { try recount(key, in: db) }
        return out
    }

    /// 단위마다 **최신 완료 실행**의 지적만으로 센다. 피드백은 모든 이력에서.
    static func recount(_ key: String, in db: Database) throws {
        guard var item = try BacklogItem.fetchOne(db, key: key) else { return }
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COUNT(DISTINCT f.unit_id) AS u, MAX(f.severity) AS s,
                   MIN(f.observed_at) AS first, MAX(f.observed_at) AS last
            FROM finding f
            WHERE f.backlog_key = ? AND f.run_id = (
                SELECT r.id FROM evaluation_run r WHERE r.unit_id = f.unit_id AND r.status = 'done'
                ORDER BY r.finished_at DESC, r.created_at DESC LIMIT 1)
            """, arguments: [key])
        let fb = try Row.fetchOne(db, sql: """
            SELECT SUM(feedback = 'useful') AS useful, SUM(feedback = 'false_positive') AS fp FROM finding WHERE backlog_key = ?
            """, arguments: [key])
        item.observedCount = row?["n"] ?? 0
        item.unitCount = row?["u"] ?? 0
        item.maxSeverity = row?["s"] ?? 0
        item.firstSeen = row.flatMap { $0["first"] }
        item.lastSeen = row.flatMap { $0["last"] }
        item.usefulCount = fb?["useful"] ?? 0
        item.falsePositiveCount = fb?["fp"] ?? 0
        try item.update(db)
    }

    static func setFeedback(findingID: String, _ feedback: FindingFeedback?, now: Int, in db: Database) throws {
        guard var f = try Finding.fetchOne(db, key: findingID) else { return }
        f.feedback = feedback
        f.feedbackAt = feedback == nil ? nil : now
        try f.update(db)
        try recount(f.backlogKey, in: db)
    }

    static func setState(_ key: String, _ state: BacklogState, linkedIssue: String?, now: Int, in db: Database) throws {
        guard var i = try BacklogItem.fetchOne(db, key: key) else { return }
        i.state = state
        if state == .resolved { i.resolvedAt = now }
        if let linkedIssue { i.linkedIssue = linkedIssue }
        try i.update(db)
    }
}
