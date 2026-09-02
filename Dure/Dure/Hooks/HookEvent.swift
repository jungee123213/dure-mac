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
    /// SessionStart 가 **실제 적용된** 모델을 준다. 사용자가 고른 값(repo.model)과는 별개다.
    var model: String? { payload?["model"] as? String }
}
