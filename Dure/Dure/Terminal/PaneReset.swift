import Foundation

/// 이슈 #14 — claude 가 끝나면(`/exit` · 비정상 종료) 페인을 시작 대기로 되돌린다.
/// 조율자 설계 8절: "돌던 세션을 `/exit` 하면 페인이 종료되고 같은 시작 화면이 다시 뜬다".
///
/// 순수 함수로 뺀 이유 — 스토어는 실제 DB 를 써서 테스트하기 어렵고, 틀리면 조용히 틀리는
/// 판단이 이것 하나다. **늦게 도착한 옛 세션의 종료 신호가 새로 시작한 세션을 지우면**
/// 살아 있는 claude 의 페인이 시작 대기로 바뀌고, 그 claude 는 화면 없이 남는다.
enum PaneReset {

    /// 종료된 세션이 **지금 그 레포에 걸린 세션일 때만** 레포 id 를 돌려준다.
    static func repoToReset(exitedSession: String, sessionIDs: [String: String]) -> String? {
        sessionIDs.first { $0.value == exitedSession }?.key
    }
}
