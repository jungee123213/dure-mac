import Foundation

/// 이슈 #40 — 배분 작업 흐름(스펙 2절)의 **원본 하나.** 작업 흐름 안내 창과 조율자 지시문(`OrchestratorDoc`)이 같이 쓴다 —
/// 둘이 따로 놀지 않게. 레포 페인 꼬리말(`DispatchBody`)은 페인에게 하는 명령형이라 문장은 다르다. 꼬리말은 단계 순서만 맞춘다 (번호는 다르다).
///
/// 순수 데이터. 상태 · DB 를 읽지 않는다.
enum WorkflowGuide {

    struct Step: Identifiable, Equatable {
        let id: Int
        let title: String
        /// 그 단계를 하는 쪽 — 사람 · 조율자 · 레포 페인.
        let who: String
        let detail: String
    }

    /// 배분 종류. 조율자가 `dispatch` 칸으로 고른다(`DispatchGit` 의 판정과 같은 셋).
    struct Kind: Identifiable, Equatable {
        let id: String
        let name: String
        let when: String
        /// 레포 페인이 하는 git.
        let git: String
    }

    static let steps: [Step] = [
        .init(id: 1, title: "상의", who: "사람 · 조율자",
              detail: "조율자가 기능명세서 · 코드를 훑고 배분안을 낸다. 레포마다 배분 종류(아래 표) + 작업 지시, 새 이슈면 이슈 초안(제목 · 본문), git 을 쓰면 git 범위(커밋까지 / PR 까지)."),
        .init(id: 2, title: "진행", who: "사람",
              detail: "사람이 \"진행\" 이라고 하면 조율자가 dispatch 한다. 이 한 번이 그 배분의 이슈 등록 · 브랜치 · 커밋(· PR) 승인이다."),
        .init(id: 3, title: "검증", who: "레포 페인",
              detail: "이슈 초안 · 지시를 현재 코드와 대조한다(이미 있음 · 위치 다름 · 범위 다름 · 빠진 것). 어긋나면 report 로 차이와 수정안을 조율자에게 올리고, 그 페인 터미널에서 사람에게 묻고 멈춘다 — 배분은 waiting(응답 대기). 사람이 그 페인에 답하면 같은 배분을 이어간다. 맞으면 다음 단계로."),
        .init(id: 4, title: "등록", who: "레포 페인",
              detail: "레포 이슈 템플릿 형식으로 이슈를 만든다(gh issue create) → 이슈 번호. 새 이슈 배분만."),
        .init(id: 5, title: "작업", who: "레포 페인",
              detail: "기준 브랜치 최신에서 type/#번호/작업명 브랜치를 만들고(이어 하기면 그 브랜치로 옮기고) 구현 → 빌드 · 테스트 → 그 브랜치에 커밋. 등록 뒤 멈추지 않고 이어간다."),
        .init(id: 6, title: "PR", who: "레포 페인",
              detail: "git 범위가 PR 까지일 때만 push 하고 PR 을 연다. 머지는 배분으로 시키지 않는다 — 사람이 PR 을 본 뒤에 한다."),
        .init(id: 7, title: "보고", who: "레포 페인 · 조율자",
              detail: "레포 페인이 complete 로 요약 + 이슈 번호 · 브랜치 · (PR) 을 올리고, 조율자가 사람에게 전한다."),
    ]

    static let kinds: [Kind] = [
        .init(id: "new_issue", name: "새 이슈",
              when: "새 작업",
              git: "검증 → 이슈 등록 → 새 브랜치 · 커밋 (→ PR)"),
        .init(id: "continue", name: "이어 하기",
              when: "보고 뒤 보완 · 기기 확인 뒤 수정 · PR 리뷰 반영처럼 이미 있는 이슈 · 브랜치에 이어서",
              git: "검증 → 그 브랜치로 옮겨 작업 · 커밋 (→ push · PR 이 없으면 생성)"),
        .init(id: "none", name: "git 없음",
              when: "조사 · 질문 · 비교처럼 코드를 안 바꾸는 일",
              git: "없음. 코드를 바꿔야 할 것 같으면 사람에게 묻는다"),
    ]

    /// 단계 번호 목록 + 종류 표. 조율자 지시문에 그대로 들어간다.
    static func markdown() -> String {
        var out = steps.map { "\($0.id). **\($0.title)** (\($0.who)) — \($0.detail)" }.joined(separator: "\n")
        out += "\n\n| 배분 | 언제 | 페인이 하는 git |\n|---|---|---|\n"
        out += kinds.map { "| **\($0.name)** | \($0.when) | \($0.git) |" }.joined(separator: "\n")
        return out + "\n"
    }
}
