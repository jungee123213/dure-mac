import Foundation

/// 단계 4 — 페인에 들어가는 글과 조율자에게 올라가는 글. 설계 3-2절.
///
/// **순수 함수.** 받는 Claude 는 이 글을 `Another Claude session sent a message:` 로 감싸 보고,
/// 우리가 넣는 발신자 이름 필드는 무시한다(실측). 그래서 **첫 줄이 발신자**다.
enum DispatchBody {

    static func dispatch(seq: Int, repoName: String, instruction: String) -> String {
        """
        [두레] 조율자 배분 #\(seq) — \(repoName)
        \(instruction)
        ---
        다 끝나면 complete 툴에 결과를 한 문단으로 요약해 넣어라 — 두레가 조율자에게 전달하고 이 배분을 닫는다.
        사람에게 묻거나 승인을 기다리느라 멈추는 것은 끝난 게 아니다 — 그때는 complete 를 부르지 않는다.
        레포 사이 판단이 막히면 ask_orchestrator 툴로 조율자에게 묻는다. 사람 승인이 필요한 일은 이 터미널에서 그대로 묻는다.
        커밋·브랜치·push 는 하지 않는다. 사람이 한다.
        """
    }

    static func relay(_ kind: RelayKind, seq: Int?, repoName: String, body: String, time: String) -> String {
        let head: String
        switch kind {
        case .completion: head = "배분 #\(seq ?? 0) 끝남 (\(time))"
        case .failure:    head = "배분 #\(seq ?? 0) 실패 (\(time))"
        case .report:     head = seq.map { "보고 (배분 #\($0), \(time))" } ?? "보고 (\(time))"
        case .question:   head = seq.map { "질문 (배분 #\($0), \(time))" } ?? "질문 (\(time))"
        }
        return "[두레] ‹\(repoName)› \(head)\n\(body)"
    }

    /// 조율자가 안 떠 있는 동안 쌓인 것을 첫 프롬프트 하나로.
    static func bundle(_ parts: [String]) -> String {
        parts.joined(separator: "\n\n---\n\n")
    }
}
