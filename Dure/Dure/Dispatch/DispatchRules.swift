import Foundation

/// 단계 4 — "지금 넣어도 되나" 의 판단. 설계 3절. 순수 함수로 둔 이유는 `Dispatcher` 가 DB · 소켓을 쓰고,
/// 틀리면 조용히 틀리는 판단이 이것이기 때문이다 — 일하는 중에 넣으면 하던 일과 섞인다(D-29).
enum DispatchRules {

    static let maxAttempts = 3

    /// - started: 페인이 떠 있다(`startedPanes`).
    /// - state: 앱이 훅으로 아는 상태. `nil` 은 `SessionStart` 전 — 폴더 신뢰 확인 중일 수 있다.
    /// - hasOutstanding: 전달했는데 `Stop` 을 못 봤다. 소켓이 시작한 턴에 `UserPromptSubmit` 이 뜨는지
    ///   미확인이라 상태만 믿지 않는다.
    static func isIdle(started: Bool, state: AgentState?, hasOutstanding: Bool) -> Bool {
        guard started, !hasOutstanding else { return false }
        switch state {
        case .started, .done: return true
        case .running, .waiting, .dead, nil: return false
        }
    }

    static func givesUp(afterAttempts n: Int) -> Bool { n >= maxAttempts }

    /// 이슈 #24 — 열린 배분이 있는 레포 페인에 `SessionStart` 가 왔을 때.
    nonisolated enum SessionStartAction: Equatable { case adopt, keep, fail }

    /// - adopt: 기동 프롬프트(argv)로 실은 배분 — 이 세션이 그 배분을 받은 세션이다.
    /// - keep: 같은 세션의 압축 · 재개 — 하던 일이 이어진다.
    /// - fail: `/clear` 나 다른 세션 — 그 배분의 대화가 끊겼다. `complete` 가 올 수 없으니 닫는다.
    static func onSessionStart(deliveredSession: String?, newSession: String, source: String) -> SessionStartAction {
        guard let delivered = deliveredSession, delivered != "argv" else { return .adopt }
        if source == "clear" { return .fail }
        return delivered == newSession ? .keep : .fail
    }

    /// 이 훅을 배분 흐름에 넘겨도 되나. 같은 페인을 다시 시작하면 새 세션이 생기는데, 죽은 옛 세션의 늦은 `Stop` 이
    /// 오면 **새 세션에 간 배분**을 옛 세션의 마지막 말로 닫아 버린다. `AgentStateMachine` 이 죽은 세션의 이벤트를
    /// `.ignore` 로 거르는 것과 같은 불변식 — 지금 그 페인의 세션이 보낸 것만 받는다.
    /// - current: 이벤트를 보낸 세션(agent 행)의 상태.
    /// - sessionOfPane: 그 페인의 **지금** `DURE_SESSION`. 페인이 죽어 지워졌으면 nil.
    static func acceptsHook(current: AgentState?, sessionOfPane: String?, eventSession: String) -> Bool {
        current != .dead && sessionOfPane == eventSession
    }

    /// `nonisolated` 인 이유 — 기본 격리(MainActor)면 `Equatable` 적합성도 메인액터에 묶여 `#expect` 에서 Swift 6 경고가 난다.
    nonisolated enum CancelRef: Equatable { case seq(Int), id(String) }

    static func cancelRef(_ raw: String) -> CancelRef {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if let n = Int(digits), !digits.isEmpty { return .seq(n) }
        return .id(t)
    }

    static func clock(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
