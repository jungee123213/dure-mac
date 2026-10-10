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

    static func waitingHint(queueCount: Int, firstSeq: Int?) -> String? {
        guard queueCount > 0, let n = firstSeq else { return nil }
        return queueCount == 1 ? "시작하면 #\(n) 을 싣습니다" : "시작하면 #\(n) 을 싣습니다 (대기 \(queueCount))"
    }
}
