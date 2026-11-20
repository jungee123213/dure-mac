import Foundation

/// 단계 4 — 대시보드 ④ · 페인 배지의 글. 뷰는 테스트하지 않으므로 글 만드는 부분만 순수 함수로 뺐다.
enum DispatchPresentation {

    static func stateLabel(_ s: DispatchState) -> String {
        switch s {
        case .queued: "큐 대기"
        case .delivered: "전달됨"
        case .waiting: "응답 대기"
        case .done: "완료"
        case .failed: "실패"
        case .cancelled: "취소"
        }
    }

    static func line(_ d: Dispatch, repoName: String) -> String {
        var s = "#\(d.seq) \(repoName) · \(stateLabel(d.state))"
        switch d.state {
        case .delivered, .waiting: if let t = d.deliveredAt { s += " \(DispatchRules.clock(t))" }
        case .done:      if let t = d.doneAt { s += " \(DispatchRules.clock(t))" }
        case .failed:    if let f = d.failure { s += " (\(f))" }
        case .queued, .cancelled: break
        }
        return s
    }

    /// 카드의 git 한 줄. 종류와 있는 값만. git 도 값도 없으면 nil.
    static func gitLine(_ d: Dispatch) -> String? {
        var parts: [String] = []
        switch d.gitMode {
        case .newIssue: parts.append("새 이슈")
        case .continueWork: parts.append("이어 하기")
        case nil: break
        }
        if let n = d.issueNumber { parts.append("이슈 #\(n)") }
        if let b = d.branch { parts.append(b) }
        if let p = d.prNumber { parts.append("PR #\(p)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func headline(_ d: Dispatch) -> String {
        if let t = d.title, !t.isEmpty { return t }
        let first = d.instruction.split(separator: "\n").first.map(String.init) ?? ""
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    static func relayLabel(_ r: Relay) -> String {
        switch r.kind {
        case .completion: "완료 보고"
        case .report: "보고"
        case .question: "질문"
        case .failure: "실패"
        case .answerFailure: "답 전달 실패"
        case .limit: "Codex 한도"
        }
    }

    /// 대시보드 ④ 의 묶음. 배분에 딸린 relay 는 그 카드 밑으로, 배분이 없거나(배분 밖에서 한 `report`/`ask`)
    /// 목록에 없는 배분을 가리키는 relay 는 **고아**로 따로 — 버리면 레포의 보고 · 질문이 화면에서 사라진다.
    /// 들어온 순서(각 묶음 안의 순서)를 그대로 둔다.
    static func group(relays: [Relay], dispatchIDs: Set<String>) -> (byDispatch: [String: [Relay]], orphans: [Relay]) {
        var by: [String: [Relay]] = [:]
        var orphans: [Relay] = []
        for r in relays {
            if let id = r.dispatchId, dispatchIDs.contains(id) { by[id, default: []].append(r) } else { orphans.append(r) }
        }
        return (by, orphans)
    }

    /// 조율자가 보낸 답의 행 라벨. 실패 사유는 저장된 글을 그대로 보인다.
    static func answerLabel(_ a: Answer) -> String {
        switch a.state {
        case .queued: "답 · 대기"
        case .delivered: "답"
        case .failed: a.failure.map { "답 · 실패: \($0)" } ?? "답 · 실패"
        }
    }

    /// `group(relays:)` 와 같은 묶음 — 답이 열린 배분이 아니라 **질문이 나온 배분**에 붙는다.
    static func group(answers: [Answer], dispatchIDs: Set<String>) -> (byDispatch: [String: [Answer]], orphans: [Answer]) {
        var by: [String: [Answer]] = [:]
        var orphans: [Answer] = []
        for a in answers {
            if let id = a.dispatchId, dispatchIDs.contains(id) { by[id, default: []].append(a) } else { orphans.append(a) }
        }
        return (by, orphans)
    }

    /// 배분 카드 밑의 한 줄 — 레포가 올린 relay 또는 조율자가 보낸 답.
    enum CardRow: Identifiable, Equatable {
        case relay(Relay), answer(Answer)
        var id: String {
            switch self {
            case .relay(let r): "r:\(r.id)"
            case .answer(let a): "a:\(a.id)"
            }
        }
        var createdAt: Int {
            switch self {
            case .relay(let r): r.createdAt
            case .answer(let a): a.createdAt
            }
        }
    }

    /// 카드 밑 줄 — relay 와 답을 오래된 것부터 한 목록으로(설계 6절 "질문 relay 다음에"). 답을 모든 relay 밑에 따로 두면
    /// 질문 · 답 · 완료 보고가 질문 · 완료 보고 · 답으로 읽힌다.
    /// 같은 초면 relay 가 먼저다 — 답은 질문 뒤에야 생긴다(`created_at` 은 초 단위). 그 밖의 같은 초는 각 목록의 순서를 지킨다.
    /// 정렬의 안정성은 문서로 보장되지 않으므로 색인을 같이 비교한다.
    static func cardRows(relays: [Relay], answers: [Answer]) -> [CardRow] {
        let rows = relays.map(CardRow.relay) + answers.map(CardRow.answer)
        func rank(_ r: CardRow) -> Int { if case .relay = r { 0 } else { 1 } }
        return rows.enumerated().sorted { a, b in
            if a.element.createdAt != b.element.createdAt { return a.element.createdAt < b.element.createdAt }
            if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func waitingHint(queueCount: Int, firstSeq: Int?) -> String? {
        guard queueCount > 0, let n = firstSeq else { return nil }
        return queueCount == 1 ? "시작하면 #\(n) 을 싣습니다" : "시작하면 #\(n) 을 싣습니다 (대기 \(queueCount))"
    }
}
