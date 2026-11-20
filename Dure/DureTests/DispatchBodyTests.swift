import Foundation
import Testing
@testable import Dure

/// 단계 4 — 받는 Claude 에게 보이는 글. **발신자 이름 필드는 무시된다(실측)** 라 본문 첫 줄이 발신자다.
struct DispatchBodyTests {

    static func row(seq: Int = 7, instruction: String = "지시", mode: GitMode? = nil,
                    title: String? = nil, body: String? = nil, scope: GitScope? = nil,
                    hint: String? = nil, base: String? = nil, issue: Int? = nil, branch: String? = nil) -> Dispatch {
        var d = Dispatch(workspaceId: "w1", seq: seq, repoId: "r1", title: nil, instruction: instruction,
                         state: .queued, toolUseId: nil, deliveredSession: nil, result: nil, failure: nil,
                         createdAt: 0, deliveredAt: nil, doneAt: nil)
        d.gitMode = mode; d.issueTitle = title; d.issueBody = body; d.gitScope = scope
        d.branchHint = hint; d.baseBranch = base; d.issueNumber = issue; d.branch = branch
        return d
    }

    @Test func 배분_본문은_번호_레포_지시문_꼬리_순이다() {
        let s = DispatchBody.dispatch(Self.row(instruction: "로그인 버튼을 파랑으로"), repoName: "android")
        #expect(s.hasPrefix("[두레] 조율자 배분 #7 — android\n"))
        #expect(s.contains("\n로그인 버튼을 파랑으로\n"))
        #expect(s.contains("ask_orchestrator"))
        #expect(s.contains("complete"))           // 이슈 #24 — 완료는 툴로 선언한다
        #expect(s.contains("이슈 · 브랜치 · 커밋을 하지 않는다"))
        #expect(!s.contains("## "))
        #expect(s.components(separatedBy: "\n---\n").count == 2)
    }

    @Test func 새_이슈_배분은_초안_지시_범위_순서를_싣는다() throws {
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "[FEAT] 공유", body: "본문입니다",
                                               scope: .commit, hint: "feat/#N/share"), repoName: "android")
        var at = s.startIndex
        for key in ["## 이슈 초안", "제목: [FEAT] 공유", "본문입니다", "## 작업 지시", "지시", "## git 범위", "커밋까지", "feat/#N/share", "\n---\n"] {
            let r = try #require(s.range(of: key, range: at..<s.endIndex), "\(key) 없음 또는 순서 어긋남")
            at = r.upperBound
        }
        for key in ["report", "이슈를 만든다", "멈추지 않고", "머지는 하지 않는다", "complete", "ask_orchestrator", "끝난 게 아니다"] {
            #expect(s.contains(key), "\(key)")
        }
        #expect(s.components(separatedBy: "\n---\n").count == 2)
    }

    @Test func 기준_브랜치를_지정하면_싣는다() {
        let with = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .commit, base: "feat/#9/base"), repoName: "a")
        #expect(with.contains("기준 브랜치 feat/#9/base"))
        let without = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .commit), repoName: "a")
        #expect(without.contains("레포 기본 브랜치 최신"))
        #expect(without.contains("이슈 접두사로 정한다"))
    }

    @Test func PR_범위면_push_와_PR_을_말한다() {
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .pr), repoName: "a")
        #expect(s.contains("PR 까지"))
        #expect(s.contains("push"))
    }

    @Test func 이어_하기는_이슈와_브랜치를_대고_새로_따지_말라고_한다() {
        let s = DispatchBody.dispatch(Self.row(mode: .continueWork, scope: .commit, issue: 165, branch: "feat/#165/x"), repoName: "a")
        #expect(s.contains("## 이어 하기"))
        #expect(s.contains("이슈 #165 · 브랜치 feat/#165/x"))
        #expect(s.contains("새 이슈를 만들지 않는다"))
        #expect(s.contains("## 작업 지시") && s.contains("## git 범위"))
        #expect(!s.contains("## 이슈 초안"))
        #expect(s.contains("complete") && s.contains("ask_orchestrator") && s.contains("끝난 게 아니다"))
        #expect(s.components(separatedBy: "\n---\n").count == 2)
    }

    /// 최종 리뷰 I-2 — 꼬리말이 명령 모양을 대지 않으면 모델이 `git checkout main && git pull` · `gh pr list` 처럼
    /// 허용 밖 모양을 골라 권한 창에 멈춘다. 허용 목록(`SessionSettings.repoGitAllow`)과 같은 모양을 댄다.
    @Test func 새_이슈_꼬리말은_허용된_명령_모양을_댄다() throws {
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .pr, base: "feat/#9/base"), repoName: "a")
        var at = try #require(s.range(of: "\n---\n")).upperBound
        for key in ["git status --porcelain", "gh issue create", "git fetch origin",
                    "git switch -c <브랜치> origin/feat/#9/base", "git add <파일…>", "git push -u origin <브랜치>", "gh pr create"] {
            let r = try #require(s.range(of: key, range: at..<s.endIndex), "\(key) 없음 또는 순서 어긋남")
            at = r.upperBound
        }
        for key in ["커밋 안 한 변경이 있으면 건드리지 않고", "git add -A · git add . 는 쓰지 않는다", "맨 git push 는 쓰지 않는다",
                    "; echo $?", "#N 을 새 이슈 번호로", "complete 의 issue · branch · pr 칸에 넣는다",
                    "범위를 바꿔야 하면 사람에게 묻는다", "gh pr create --base feat/#9/base", "작은따옴표 heredoc", "제목은 작은따옴표로",
                    "읽기(git log · git diff 등)는 필요한 대로 한다"] {
            #expect(s.contains(key), "\(key)")
        }
        #expect(!s.contains("1번으로 간다"))
        #expect(!s.contains("gh pr list 로"), "새 브랜치라 PR 이 있을 수 없다")
    }

    @Test func 기준_브랜치가_없으면_기본_브랜치를_읽는_명령을_댄다() {
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .commit), repoName: "a")
        #expect(s.contains("git switch -c <브랜치> origin/<기본 브랜치>"))
        #expect(s.contains("git rev-parse --abbrev-ref origin/HEAD"))
        #expect(!s.contains("--base"), "기준 브랜치가 없으면 gh 기본(레포 기본 브랜치)으로 연다")
    }

    @Test func 이어_하기_꼬리말은_그_브랜치_이름으로_명령을_댄다() throws {
        let s = DispatchBody.dispatch(Self.row(mode: .continueWork, scope: .pr, issue: 165, branch: "feat/#165/x"), repoName: "a")
        var at = try #require(s.range(of: "\n---\n")).upperBound
        for key in ["git status --porcelain", "git fetch origin", "git switch feat/#165/x", "(레포 CLAUDE.md 의 커밋 형식)",
                    "git add <파일…>", "git push -u origin feat/#165/x", "gh pr create"] {
            let r = try #require(s.range(of: key, range: at..<s.endIndex), "\(key) 없음 또는 순서 어긋남")
            at = r.upperBound
        }
        for key in ["이미 있어 gh pr create 가 실패하면", "gh pr list 로 찾지 않는다", "맨 git push 는 쓰지 않는다", "; echo $?",
                    "complete 의 issue · branch · pr 칸에 넣는다", "작은따옴표 heredoc", "그 오류에 나온 PR 번호를 쓴다"] {
            #expect(s.contains(key), "\(key)")
        }
        #expect(!s.contains("git switch -c"))
        #expect(!s.contains("--base"))
    }

    @Test func 승인_문장은_구분선_바로_다음_줄이다() throws {
        let n = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .pr), repoName: "a")
        let c = DispatchBody.dispatch(Self.row(mode: .continueWork, scope: .pr, issue: 1, branch: "b"), repoName: "a")
        for s in [n, c] {
            let tail = try #require(s.components(separatedBy: "\n---\n").last)
            #expect(tail.hasPrefix("이 배분이 사람의 "), "\(tail.prefix(40))")
        }
    }

    /// M-1 — 본문 안의 `## ` · `---` 가 초안 경계와 섞이지 않게 표시로 감싼다.
    @Test func 이슈_본문은_표시로_감싼다() {
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "[FEAT] 공유", body: "## 할 일\n- a", scope: .commit), repoName: "a")
        #expect(s.contains("## 이슈 초안\n제목: [FEAT] 공유\n<이슈 본문>\n## 할 일\n- a\n</이슈 본문>\n## 작업 지시"))
        #expect(s.contains("<이슈 본문> · </이슈 본문> 표시 사이 글 그대로"))
    }

    @Test func 이_배분이_승인이라고_말한다() {
        let n = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .pr), repoName: "a")
        let c = DispatchBody.dispatch(Self.row(mode: .continueWork, scope: .pr, issue: 1, branch: "b"), repoName: "a")
        let g = DispatchBody.dispatch(Self.row(), repoName: "a")
        #expect(n.contains("이 배분이 사람의 이슈 등록 · 브랜치 · 커밋(· PR) 승인이다"))
        #expect(c.contains("이 배분이 사람의 브랜치 · 커밋(· PR) 승인이다"))
        #expect(n.contains("커밋 승인 절차를 다시 밟지 않는다") && c.contains("커밋 승인 절차를 다시 밟지 않는다"))
        #expect(!g.contains("승인이다"))
    }

    @Test func 불일치_뒤_사람이_답하면_같은_배분을_이어간다() {
        let n = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: "b", scope: .commit), repoName: "a")
        let c = DispatchBody.dispatch(Self.row(mode: .continueWork, scope: .commit, issue: 1, branch: "b"), repoName: "a")
        #expect(n.contains("사람이 답하면 그 답대로 초안을 고쳐 2번부터 이어간다 — 다시 report 하지 않는다"))
        #expect(c.contains("답을 받으면 그 답대로 2번부터 이어간다"))
    }

    @Test func 이슈_본문은_그대로_간다() {
        let body = "## 할 일\n\n- [ ] `A.swift` 🚀\n- 한글"
        let s = DispatchBody.dispatch(Self.row(mode: .newIssue, title: "t", body: body, scope: .commit), repoName: "a")
        #expect(s.contains(body))
    }

    @Test func 지시문의_줄바꿈과_마크다운이_그대로다() {
        let s = DispatchBody.dispatch(Self.row(seq: 1, instruction: "## 할 일\n\n- `a.swift`\n- b"), repoName: "ios")
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

    @Test func 답_전달_실패는_배분_실패와_다른_머리말이다() {
        #expect(DispatchBody.relay(.answerFailure, seq: 3, repoName: "a", body: "b", time: "t") == "[두레] ‹a› 답 전달 실패 (배분 #3, t)\nb")
        #expect(DispatchBody.relay(.answerFailure, seq: nil, repoName: "a", body: "b", time: "t") == "[두레] ‹a› 답 전달 실패 (t)\nb")
    }

    @Test func 배분_번호_없는_실패는_배분_0_으로_쓰지_않는다() {
        #expect(DispatchBody.relay(.failure, seq: nil, repoName: "a", body: "b", time: "t") == "[두레] ‹a› 실패 (t)\nb")
    }

    @Test func 묶음은_구분선으로_잇는다() {
        #expect(DispatchBody.bundle(["하나", "둘"]) == "하나\n\n---\n\n둘")
        #expect(DispatchBody.bundle(["하나"]) == "하나")
    }

    // MARK: - 조율자 답

    @Test func 답_본문은_머리말_질문_첫줄_답_꼬리_순이다() {
        let s = DispatchBody.answer(seq: 3, question: "API 이름은?\n둘째 줄", body: "fetchUser 로")
        #expect(s == """
        [두레] 조율자 답 (배분 #3)
        질문: API 이름은?
        fetchUser 로

        이 답대로 배분 #3 을 이어 간다. 다 끝나면 complete 를 부른다.
        사람이 이 터미널에서 이미 다르게 답했으면 사람의 답을 따르고, 어긋난다고 짧게 알린다.
        """)
    }

    @Test func 배분이_없으면_이어_간다_줄이_없다() {
        let s = DispatchBody.answer(seq: nil, question: "Q", body: "A")
        #expect(s.hasPrefix("[두레] 조율자 답 (배분 없음)\n"))
        #expect(!s.contains("이어 간다"))
        #expect(s.hasSuffix("사람이 이 터미널에서 이미 다르게 답했으면 사람의 답을 따르고, 어긋난다고 짧게 알린다."))
    }

    @Test func 질문_첫줄이_120자를_넘으면_자른다() {
        let long = String(repeating: "가", count: 121)
        let cut = DispatchBody.answer(seq: 1, question: long, body: "A")
        #expect(cut.contains("질문: " + String(repeating: "가", count: 120) + "…\n"))
        let exact = String(repeating: "가", count: 120)
        let kept = DispatchBody.answer(seq: 1, question: exact, body: "A")
        #expect(kept.contains("질문: " + exact + "\n"))
        #expect(!kept.contains("…"))
    }

    @Test func 질문이_없으면_질문_줄이_없다() {
        let s = DispatchBody.answer(seq: 2, question: nil, body: "A")
        #expect(!s.contains("질문:"))
        #expect(s.hasPrefix("[두레] 조율자 답 (배분 #2)\nA\n"))
    }

    // MARK: - Codex 판 (2단계 Task 5)

    static func allForms() -> [Dispatch] {
        [row(mode: .newIssue, title: "제목", body: "본문", scope: .pr, hint: "feat/#N/x"),
         row(mode: .continueWork, scope: .pr, issue: 3, branch: "feat/#3/x"),
         row()]
    }

    @Test func Codex_판에는_heredoc_과_명령_치환이_없다() {
        for d in Self.allForms() {
            let s = DispatchBody.dispatch(d, repoName: "android", kind: .codex)
            #expect(!s.contains("$("), "\(d.gitMode as Any)")
            #expect(!s.contains("<<"))
        }
    }

    @Test func Codex_판은_AGENTS_md_를_먼저_가리킨다() {
        for d in Self.allForms().dropLast() {
            let s = DispatchBody.dispatch(d, repoName: "android", kind: .codex)
            #expect(s.contains("레포 AGENTS.md(없으면 CLAUDE.md)"))
            #expect(!s.contains("레포 CLAUDE.md 의"))
        }
    }

    @Test func Codex_판은_작은따옴표_인용_규칙을_적는다() {
        let s = DispatchBody.dispatch(Self.allForms()[1], repoName: "android", kind: .codex)
        #expect(s.contains("--title '<제목>' --body '<본문>'. 안의 작은따옴표는 '\\'' 로 쓴다."))
        #expect(s.contains("git commit -m '<메시지>' 한 덩어리로(여러 줄 가능, 같은 인용 규칙)"))
        let n = DispatchBody.dispatch(Self.allForms()[0], repoName: "android", kind: .codex)
        #expect(n.contains("git commit -m '<메시지>'"))
        #expect(n.contains("작은따옴표 한 덩어리로 넘긴다"))
    }

    @Test func Claude_판은_그대로다() {
        for d in Self.allForms() {
            let s = DispatchBody.dispatch(d, repoName: "android")
            #expect(s == DispatchBody.dispatch(d, repoName: "android", kind: .claude))
            #expect(!s.contains("AGENTS.md"))
            #expect(!s.contains("git commit -m"))
            if d.gitMode != nil { #expect(s.contains("<<'EOF'")) }
        }
    }

    @Test func 따옴표와_달러가_든_이슈_제목도_Codex_판에_그대로_실린다() {
        let d = Self.row(mode: .newIssue, title: "it's $HOME `x`", body: "a'b $(x)", scope: .commit)
        let s = DispatchBody.dispatch(d, repoName: "android", kind: .codex)
        #expect(s.contains("제목: it's $HOME `x`"))
        #expect(s.contains("a'b $(x)"))
    }

    // MARK: - Codex 한도 (4단계 Task 4)

    static let seoul = TimeZone(identifier: "Asia/Seoul")!

    @Test func 한도_안내는_다시_볼_시각과_큐에_쌓인다는_말을_싣는다() {
        // 05:07 UTC = 14:07 서울
        let s = DispatchBody.limitNotice(until: 5 * 3600 + 7 * 60, timeZone: Self.seoul)
        #expect(s.contains("14:07"))
        #expect(s.contains("Codex 페인 배분은 그때까지 큐에 쌓인다"))
        #expect(!s.contains("$(") && !s.contains("<<"))
    }

    @Test func 시각은_H_mm_이다() {
        #expect(DispatchBody.hourMinute(0, timeZone: Self.seoul) == "9:00")
        #expect(DispatchBody.hourMinute(5 * 3600 + 7 * 60, timeZone: Self.seoul) == "14:07")
    }

    @Test func 이어_하기는_머리와_원래_배분_전문을_싣는다() {
        for d in Self.allForms() {
            let s = DispatchBody.resumeAfterLimit(d, repoName: "android", kind: .codex)
            #expect(s.hasPrefix("[두레] "))
            #expect(s.contains("#7"))
            #expect(s.contains("한도가 풀렸다"))
            #expect(s.contains("한도로 끊겼다 — 이어서 하라"))
            #expect(s.hasSuffix(DispatchBody.dispatch(d, repoName: "android", kind: .codex)))
            #expect(!s.contains("$(") && !s.contains("<<"))
        }
    }

    @Test func 한도_relay_는_레포_이름_없이_Codex_한도_머리를_단다() {
        let s = DispatchBody.relay(.limit, seq: nil, repoName: "?", body: "본문", time: "14:07")
        #expect(s == "[두레] Codex 한도 (14:07)\n본문")
        let r = DispatchBody.relay(.limit, seq: 3, repoName: "android", body: "본문", time: "14:07")
        #expect(r == "[두레] Codex 한도 (배분 #3, 14:07)\n본문")
    }

    @Test func 풀림_안내는_정해진_문구다() {
        #expect(DispatchBody.limitReleased == "Codex 한도가 풀렸다 — 멈춘 배분을 다시 보낸다.")
    }
}
