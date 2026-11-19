import Foundation
import Testing
@testable import Dure

/// 이슈 #40 — 배분 작업 흐름의 원본. 안내 창과 조율자 지시문이 같은 글을 쓴다(스펙 5-8).
struct WorkflowGuideTests {

    @Test func 단계는_일곱이고_순서가_맞다() {
        #expect(WorkflowGuide.steps.map(\.title) == ["상의", "진행", "검증", "등록", "작업", "PR", "보고"])
        #expect(WorkflowGuide.steps.map(\.id) == Array(1...7))
    }

    @Test func 배분은_세_종류다() {
        #expect(WorkflowGuide.kinds.map(\.name) == ["새 이슈", "이어 하기", "git 없음"])
        #expect(Set(WorkflowGuide.kinds.map(\.id)).count == 3)
    }

    @Test func 마크다운에_단계와_종류가_다_있다() {
        let md = WorkflowGuide.markdown()
        for s in WorkflowGuide.steps {
            #expect(md.contains("\(s.id). **\(s.title)**"))
            #expect(md.contains(s.detail))
        }
        for k in WorkflowGuide.kinds {
            #expect(md.contains(k.name))
            #expect(md.contains(k.when))
            #expect(md.contains(k.git))
        }
    }

    /// 스펙 2절 — "진행" 한 번이 승인이고, 어긋남은 그 페인 터미널에서 사람이 답한다. 머지는 배분으로 시키지 않는다.
    @Test func 승인_지점과_머지를_적는다() {
        let step = { (t: String) in WorkflowGuide.steps.first { $0.title == t }?.detail ?? "" }
        #expect(step("진행").contains("승인"))
        #expect(step("검증").contains("report"))
        #expect(step("검증").contains("터미널"))
        #expect(step("PR").contains("머지"))
    }

    @Test func 질문과_답_흐름을_적는다() {
        #expect(WorkflowGuide.markdown().contains("answer"))
        #expect(WorkflowGuide.questionNote.contains("answer"))
    }
}
