import Foundation

/// 훅 이벤트 하나가 들어왔을 때 무엇을 할지 정한다. F4 · F5.
///
/// `DureStore` 밖으로 뺀 이유는 **이 이슈의 급소 두 개를 테스트하기 위해서다** —
/// `idle_prompt` 를 거르는 것과, 죽은 페인이 늦은 이벤트로 되살아나지 않는 것.
/// 둘 다 조용히 틀리는 종류라 눈으로 확인하기 어렵다.
enum AgentStateMachine {

    enum Alert: Equatable {
        /// 사람 답을 기다린다. 문구는 훅이 준 것.
        case waiting(String)
        case done
    }

    struct Reaction: Equatable {
        var next: AgentState?
        var alert: Alert?
        /// `SessionStart` 의 매핑 기록 (ADR-17)
        var bridgeSession = false
        /// 응답이 끝났으니 트랜스크립트를 읽을 때다 (Step 5)
        var ingestTranscript = false

        static let ignore = Reaction()
    }

    static func reaction(to event: HookEvent, current: AgentState?) -> Reaction {
        // 죽은 페인은 되살리지 않는다. PTY 가 죽은 뒤 늦게 도착한 이벤트가
        // 상태를 `실행중` 으로 되돌리면 화면이 거짓말을 하게 된다.
        guard current != .dead else { return .ignore }

        switch event.ev {
        case "SessionStart":
            return Reaction(next: .started, bridgeSession: true)

        case "UserPromptSubmit":
            return Reaction(next: .running)

        case "Notification":
            // ⚠️ F5 의 신뢰도가 이 한 줄에 걸려 있다.
            // `idle_prompt` 는 "그냥 60초 놀고 있다" 는 뜻이라 사람이 할 일이 없다.
            // 알리면 방치한 세션마다 60초에 한 번씩 오탐이 뜨고, 사용자는 알림을 꺼버린다.
            // **상태도 바꾸지 않는다** — `대기중` 으로 보이면 그것 역시 거짓말이다.
            guard event.notificationType == "permission_prompt" else { return .ignore }
            return Reaction(next: .waiting,
                            alert: .waiting(event.message ?? "승인이 필요합니다."))

        case "Stop":
            return Reaction(next: .done, alert: .done, ingestTranscript: true)

        default:
            return .ignore
        }
    }
}
