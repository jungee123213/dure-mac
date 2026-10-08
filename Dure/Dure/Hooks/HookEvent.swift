import Foundation

/// 훅이 `~/.dure/events/` 에 떨어뜨린 파일 하나. 부록 A2.
struct HookEvent {
    /// shim 과 앱의 버전 불일치 감지용. 앱이 모르는 값이면 무시하고 로그만 남긴다.
    static let supportedVersion = 1

    let v: Int
    let ts: String
    let ev: String
    let agentKind: String
    let dureSession: String
    /// 훅 stdin JSON 을 그대로 담은 것. `UserPromptSubmit` 에는 없다 (프롬프트 전문 미기록).
    let payload: [String: Any]?

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = root["v"] as? Int,
              let ev = root["ev"] as? String,
              let dureSession = root["dure_session"] as? String
        else { return nil }

        self.v = v
        self.ev = ev
        self.dureSession = dureSession
        self.ts = root["ts"] as? String ?? ""
        self.agentKind = root["agent_kind"] as? String ?? AgentKind.claude.rawValue
        self.payload = root["payload"] as? [String: Any]
    }

    var isSupported: Bool { v == Self.supportedVersion }

    // MARK: - SessionStart 가 싣고 오는 것 (ADR-17 의 브리지)

    var ccSessionID: String? { payload?["session_id"] as? String }
    var transcriptPath: String? { payload?["transcript_path"] as? String }
    var cwd: String? { payload?["cwd"] as? String }
    /// startup|clear|resume|compact. 부록 A4 에서 NOT NULL 이다.
    var source: String { payload?["source"] as? String ?? "unknown" }
    /// ⚠️ `Notification` 의 두 갈래를 가르는 필드. F5 의 신뢰도가 여기 걸려 있다.
    /// `permission_prompt` — 진짜로 사람 답을 기다린다.
    /// `idle_prompt` — 그냥 60초 놀고 있다. **알림도 상태 변경도 하지 않는다.**
    var notificationType: String? { payload?["notification_type"] as? String }

    /// 알림 문구. 길 수 있으므로 표시할 때 자른다.
    var message: String? { payload?["message"] as? String }

    /// SessionStart 가 **실제 적용된** 모델을 준다. 사용자가 고른 값(repo.model)과는 별개다.
    var model: String? { payload?["model"] as? String }

    /// 단계 4 — `Stop` 이 싣고 오는 마지막 답. 배분의 결과이자 조율자에게 올라가는 요약이다 (실측 2026-10-08).
    var lastAssistantMessage: String? { payload?["last_assistant_message"] as? String }
}
