import Foundation
import Testing
@testable import Dure

/// 단계 4 — 받는 Claude 에게 보이는 글. **발신자 이름 필드는 무시된다(실측)** 라 본문 첫 줄이 발신자다.
struct DispatchBodyTests {

    @Test func 배분_본문은_번호_레포_지시문_꼬리_순이다() {
        let s = DispatchBody.dispatch(seq: 7, repoName: "android", instruction: "로그인 버튼을 파랑으로")
        #expect(s.hasPrefix("[두레] 조율자 배분 #7 — android\n"))
        #expect(s.contains("\n로그인 버튼을 파랑으로\n"))
        #expect(s.contains("ask_orchestrator"))
        #expect(s.contains("커밋"))
        let tail = s.components(separatedBy: "\n---\n")
        #expect(tail.count == 2)
    }

    @Test func 지시문의_줄바꿈과_마크다운이_그대로다() {
        let s = DispatchBody.dispatch(seq: 1, repoName: "ios", instruction: "## 할 일\n\n- `a.swift`\n- b")
        #expect(s.contains("## 할 일\n\n- `a.swift`\n- b"))
    }

    @Test func 완료_보고는_번호와_시각을_단다() {
        let s = DispatchBody.relay(.completion, seq: 7, repoName: "android", body: "다 했다", time: "11:40")
        #expect(s == "[두레] ‹android› 배분 #7 끝남 (11:40)\n다 했다")
    }

    @Test func 질문은_배분_번호가_없어도_된다() {
        #expect(DispatchBody.relay(.question, seq: nil, repoName: "ios", body: "왜?", time: "09:00")
                == "[두레] ‹ios› 질문 (09:00)\n왜?")
        #expect(DispatchBody.relay(.question, seq: 8, repoName: "ios", body: "왜?", time: "09:00")
                == "[두레] ‹ios› 질문 (배분 #8, 09:00)\n왜?")
    }

    @Test func 보고와_실패도_구별된다() {
        #expect(DispatchBody.relay(.report, seq: nil, repoName: "a", body: "b", time: "t").hasPrefix("[두레] ‹a› 보고 (t)"))
        #expect(DispatchBody.relay(.failure, seq: 3, repoName: "a", body: "b", time: "t").hasPrefix("[두레] ‹a› 배분 #3 실패 (t)"))
    }

    @Test func 묶음은_구분선으로_잇는다() {
        #expect(DispatchBody.bundle(["하나", "둘"]) == "하나\n\n---\n\n둘")
        #expect(DispatchBody.bundle(["하나"]) == "하나")
    }
}
