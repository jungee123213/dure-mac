import Foundation
import Testing
@testable import Dure

/// 이슈 #16 — 조율자의 `CLAUDE.md`. 조율자가 지키는 규칙은 **이 문서가 전부**다
/// (메시지 범위는 Claude Code 가 강제하지 못한다, D-31).
struct OrchestratorDocTests {

    static let md = OrchestratorDoc.render(
        workspaceName: "모바일", sessionPrefix: "dure-모바일-7f3a-",
        repos: [.init(name: "back", path: "/a/back"), .init(name: "ios", path: "/a/my ios")])

    @Test func 자동_생성_문서라고_밝힌다() {
        #expect(Self.md.contains("자동으로 만든다"))
        #expect(Self.md.contains("context.md"))
    }

    @Test func 먼저_읽을_문서를_적는다() {
        #expect(Self.md.contains("workspace.md"))
    }

    /// 허용 규칙(Task 3)과 **같은 모양**이어야 승인 없이 실행된다.
    @Test func git_읽기_명령을_허용된_모양_그대로_적는다() {
        #expect(Self.md.contains("git -C /a/back log"))
        #expect(Self.md.contains("git -C '/a/my ios' log"))
    }

    /// 이슈 #40 — 조율자는 여전히 git 에 쓰지 않는다. 이슈도 초안만 쓰고 등록 · 브랜치 · 커밋 · PR 은 레포 페인이 한다.
    @Test func git_쓰기와_cd_형태를_금지한다() {
        #expect(Self.md.contains("초안만"))
        #expect(Self.md.contains("cd"))
    }

    // MARK: - 작업 흐름 (이슈 #40)

    /// 안내 창과 같은 원본(스펙 5-8) — 지시문과 안내 창이 따로 놀지 않게.
    @Test func 작업_흐름을_싣는다() {
        #expect(Self.md.contains(WorkflowGuide.markdown()))
    }

    /// D-39 변경안 1 — 조율자는 여러 레포를 요약해 보므로 코드 사실을 틀린다.
    @Test func 확인_안_한_코드_사실을_단정하지_않는다() {
        #expect(Self.md.contains("동작 수준"))
        #expect(Self.md.contains("확인한 경로"))
    }

    /// 열린 배분이 있는 레포에는 다음 배분이 안 들어간다 — 다시 보내면 큐에 막힌다(스펙 2절).
    @Test func 어긋나면_다시_배분하지_않는다() {
        #expect(Self.md.contains("다시 dispatch 하지 않는다"))
        #expect(Self.md.contains("그 페인 터미널"))
    }

    @Test func 보완은_이어_하기로_보낸다() {
        #expect(Self.md.contains("이어 하기"))
        #expect(Self.md.contains("issue_title"))
        #expect(Self.md.contains("base"))
        // M-2 — issue_body 를 이어 하기에 주면 거절된다
        #expect(Self.md.contains("`issue_title` · `issue_body` · `base` 는 주지 않는다"))
    }

    /// 질문의 답은 `answer` 로 — 열린 배분이 큐를 막으니 `dispatch` 로 답하지 않는다. 사람이 터미널에 전하라는 옛 안내는 없다.
    @Test func 질문의_답은_answer_로_보내고_dispatch_로_답하지_않는다() {
        #expect(Self.md.contains("`answer`"))
        #expect(Self.md.contains("`dispatch` 로 답하지 않는다"))
        #expect(!Self.md.contains("사람이 그 페인 터미널에 전한다"))
        #expect(!Self.md.contains("`dispatch` 로 답한다"))
    }

    @Test func 답_전달_실패는_사람에게_알리고_자동으로_다시_보내지_않는다() {
        #expect(Self.md.contains("답 전달 실패"))
        #expect(Self.md.contains("자동으로 다시 보내지 않는다"))
        // 최종 리뷰 3 — 배분이 닫혀 못 간 답은 사람 '진행' 뒤에만, 원래 배분 종류대로 다시 보낸다. 이어 하기를 강요하지 않는다
        #expect(Self.md.contains("사람이 '진행' 하면 질문과 답을 instruction 에 넣어 다시 `dispatch` 한다(원래 배분 종류대로)"))
        #expect(!Self.md.contains("dispatch 이어 하기로 보낸다"))
    }

    /// "진행" 한 번이 이슈 등록 · 브랜치 · 커밋(· PR) 승인이다 — 사람이 그걸 알고 승인하게 밝힌다.
    @Test func 진행이_git_승인임을_밝힌다() {
        #expect(Self.md.contains("이슈 등록 · 브랜치 · 커밋(· PR) 승인"))
    }

    /// 조율자 자신의 git 쓰기 금지 줄은 남는다 — 이슈 등록을 페인에 넘겼다고 조율자가 하게 되는 게 아니다.
    @Test func 조율자는_여전히_git_에_쓰지_않는다() {
        #expect(Self.md.contains("머지"))
        #expect(!Self.md.contains("이슈는 만들지 않는다. 초안을 추천하고 생성은 사람이 한다"))
        #expect(!Self.md.contains("커밋·브랜치·push·PR·머지는 하지 않는다. 사람이 한다"))
    }

    /// `--output=<파일>` 은 git 이 파일을 쓴다. 설정이 막으므로 에이전트가 시도하지 않게 알린다.
    @Test func output_옵션을_쓰지_말라고_적는다() {
        #expect(Self.md.contains("--output"))
    }

    // MARK: - 배분 프로토콜 (단계 4 · D-32)

    @Test func 배분_툴과_순서를_적는다() {
        #expect(Self.md.contains("dispatch"))
        #expect(Self.md.contains("workspace"))
        #expect(Self.md.contains("tasks"))
        #expect(Self.md.contains("cancel"))
    }

    /// 사용자 결정 ① — 승인은 대화에서만. 이 문장이 유일한 울타리다.
    @Test func 사람의_진행_전에는_dispatch_를_부르지_않는다() {
        #expect(Self.md.contains("**사람이 \"진행\" 이라고 하기 전에는 `dispatch` 를 부르지 않는다.**"))
    }

    /// 최종 리뷰 T10 — 질문에 대한 답도 배분이다. 규칙 5 가 규칙 2 의 예외로 읽히면 안 된다.
    @Test func 질문의_답도_사람_승인_뒤에_보낸다() {
        let rule5 = Self.md.components(separatedBy: "\n").filter { $0.contains("`answer` 로 보낸다") }.joined()
        #expect(rule5.contains("'진행'"))
        #expect(rule5.contains("규칙 2"))
        #expect(Self.md.contains("`answer` 로 보낸다"))
    }

    @Test func 큐와_폴더_없는_레포를_적는다() {
        #expect(Self.md.contains("큐 대기 중인 배분도 여기 보인다"))
        #expect(Self.md.contains("폴더가 없는 레포에는 보낼 수 없다"))
    }

    @Test func 임의_판단_금지와_선택지() {
        #expect(Self.md.contains("임의"))
        #expect(Self.md.contains("선택지"))
    }

    @Test func 완료와_질문을_사람에게_전한다() {
        #expect(Self.md.contains("끝남"))
        #expect(Self.md.contains("질문"))
        #expect(Self.md.contains("다음 배분을 시작하지 않는다"))
    }

    /// 세션 간 메시지는 이제 막혀 있다 — 지시문이 "보내라" 고 하면 거부만 쌓인다.
    @Test func 세션_간_메시지_절이_없다() {
        #expect(!Self.md.contains("SendMessage"))
        #expect(!Self.md.contains("다른 세션에 메시지"))
    }

    @Test func 레포가_없어도_만든다() {
        let md = OrchestratorDoc.render(workspaceName: "빈", sessionPrefix: "dure-빈-0000-", repos: [])
        #expect(md.contains("등록된 레포가 없다"))
    }
}
