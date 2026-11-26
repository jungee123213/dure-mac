import Foundation

/// 단계 4 — 페인에 들어가는 글과 조율자에게 올라가는 글. 설계 3-2절.
///
/// **순수 함수.** 받는 Claude 는 이 글을 `Another Claude session sent a message:` 로 감싸 보고,
/// 우리가 넣는 발신자 이름 필드는 무시한다(실측). 그래서 **첫 줄이 발신자**다.
enum DispatchBody {

    /// 배분 한 건을 페인이 받는 글로. 세 꼴 — 새 이슈 · 이어 하기 · git 없음(v8 이전 행 포함). 스펙 5-3.
    static func dispatch(_ d: Dispatch, repoName: String, kind: AgentKind = .claude) -> String {
        let codex = kind == .codex
        let rules = codex ? "레포 AGENTS.md(없으면 CLAUDE.md)" : "레포 CLAUDE.md"
        let bodyRule = codex ? codexBodyRule : Self.bodyRule
        let commitHow = codex ? " " + codexCommitRule : ""
        // 이슈 #61 — Codex 는 따옴표 밖 `#` 이 든 명령에 규칙을 적용하지 않는다(spike L). Claude 는 ask 규칙이 글자 그대로라 감싸지 않는다.
        func br(_ name: String) -> String { codex ? Spawn.quoted(name) : name }
        let branchRule = codex ? " " + codexBranchRule : ""
        let head = "[두레] 조율자 배분 #\(d.seq) — \(repoName)"
        let scope = (d.gitScope == .pr ? "PR 까지" : "커밋까지")
        switch d.gitMode {
        case .newIssue:
            let base = blank(d.baseBranch)
            let baseLine = base.map { "기준 브랜치 \($0)" } ?? "기준 브랜치: 레포 기본 브랜치 최신"
            let hint = blank(d.branchHint) ?? "이슈 접두사로 정한다"
            // 기준 브랜치를 안 줬으면 기본 브랜치 이름을 읽는 명령까지 댄다(권한 창 없이 도는 읽기, 실측).
            let switchCmd = "git switch -c \(br("<브랜치>")) \(br("origin/" + (base ?? "<기본 브랜치>")))"
            let prBase = base.map { " --base \(br($0))" } ?? ""
            let baseHow = base == nil
                ? " <기본 브랜치> 는 git rev-parse --abbrev-ref origin/HEAD 가 알려 준다(origin/ 뒤 이름). 안 나오면 git branch -r 로 본다."
                : ""
            return """
            \(head)
            ## 이슈 초안
            제목: \(d.issueTitle ?? "")
            <이슈 본문>
            \(d.issueBody ?? "")
            </이슈 본문>
            ## 작업 지시
            \(d.instruction)
            ## git 범위
            \(scope) · 브랜치 제안 \(hint) · \(baseLine)
            ---
            이 배분이 사람의 이슈 등록 · 브랜치 · 커밋(· PR) 승인이다 — \(rules) 의 커밋 승인 절차를 다시 밟지 않는다. 권한 창이 뜨는 명령은 그대로 따른다.
            \(commands)
            1. 먼저 이슈 초안과 작업 지시를 현재 코드와 대조한다. 이미 있음 · 위치 다름 · 범위 다름 · 빠진 것이 있으면 report 툴로 차이와 수정안을 올리고, 이 터미널에서 사람에게 묻고 기다린다. 이슈를 만들지 않는다. 사람이 답하면 그 답대로 초안을 고쳐 2번부터 이어간다 — 다시 report 하지 않는다.
            2. 맞으면 gh issue create --title '<제목>' --body … 로 이슈를 만든다. 제목은 위 제목: 줄, 이슈 본문은 <이슈 본문> · </이슈 본문> 표시 사이 글 그대로 쓴다(표시는 넣지 않는다). \(bodyRule) 확인한 파일 경로를 보태는 정도만 고친다. 범위를 바꿔야 하면 사람에게 묻는다.
            3. git fetch origin 을 치고 \(switchCmd) 로 새 브랜치를 만들어 작업한다.\(baseHow) <브랜치> 는 브랜치 제안의 #N 을 새 이슈 번호로 바꾼 이름이다(제안이 없으면 type/#번호/작업명).\(branchRule) 이슈를 만든 뒤 멈추지 않고 이어간다.
            4. 빌드 · 테스트를 돌리고 그 브랜치에 커밋한다(\(rules) 의 커밋 형식).\(commitHow) \(addRule) git 범위가 PR 까지면 git push -u origin \(br("<브랜치>")) 로 push 하고 gh pr create\(prBase) --title '<제목>' --body … 로 PR 을 연다(본문은 레포 PR 형식, 넘기는 법은 2번과 같다). \(pushRule) 커밋까지면 push · PR 은 하지 않는다. 머지는 하지 않는다.
            5. 끝나면 complete 툴을 부른다. summary 에 무엇을 바꿨고 무엇이 남았는지, 돌린 빌드 · 테스트와 결과, 사람이 기기에서 확인할 것을 한 문단으로 넣고, 만든 이슈 번호 · 브랜치 · (PR 번호)는 complete 의 issue · branch · pr 칸에 넣는다. 두레가 조율자에게 전달하고 이 배분을 닫는다.
            \(common)
            """
        case .continueWork:
            let branch = d.branch ?? "<브랜치>"
            return """
            \(head)
            ## 이어 하기
            이슈 #\(d.issueNumber.map(String.init) ?? "?") · 브랜치 \(d.branch ?? "?")
            ## 작업 지시
            \(d.instruction)
            ## git 범위
            \(scope)
            ---
            이 배분이 사람의 브랜치 · 커밋(· PR) 승인이다 — \(rules) 의 커밋 승인 절차를 다시 밟지 않는다. 권한 창이 뜨는 명령은 그대로 따른다.
            \(commands)
            1. 작업 지시를 현재 코드와 그 브랜치 상태에 대조한다. 어긋나면 report 툴로 올리고, 이 터미널에서 사람에게 묻고 멈춘다. 답을 받으면 그 답대로 2번부터 이어간다.
            2. git fetch origin 을 치고 git switch \(br(branch)) 로 그 브랜치로 옮긴다(로컬에 없으면 git 이 원격 브랜치에서 만든다). 기준 브랜치에서 새로 따지 않고, 새 이슈를 만들지 않는다.
            3. 작업하고 빌드 · 테스트를 돌린 뒤 그 브랜치에 커밋한다(\(rules) 의 커밋 형식).\(commitHow) \(addRule) git 범위가 PR 까지면 git push -u origin \(br(branch)) 로 push 하고 gh pr create --title '<제목>' --body … 로 PR 을 연다(본문은 레포 PR 형식). \(bodyRule) 그 브랜치의 PR 이 이미 있어 gh pr create 가 실패하면 있는 것으로 보고 push 만으로 끝낸다 — 그 오류에 나온 PR 번호를 쓴다(gh pr list 로 찾지 않는다). \(pushRule) 커밋까지면 push · PR 은 하지 않는다. 머지는 하지 않는다.
            4. 끝나면 complete 툴을 부른다. summary 에 무엇을 바꿨고 무엇이 남았는지, 돌린 빌드 · 테스트와 결과, 사람이 기기에서 확인할 것을 한 문단으로 넣고, 이슈 번호 · 브랜치 · (PR 번호)는 complete 의 issue · branch · pr 칸에 넣는다. 두레가 조율자에게 전달하고 이 배분을 닫는다.
            \(common)
            """
        case nil:
            return """
            \(head)
            \(d.instruction)
            ---
            다 끝나면 complete 툴에 결과를 한 문단으로 요약해 넣어라 — 두레가 조율자에게 전달하고 이 배분을 닫는다.
            \(common)
            이 배분은 이슈 · 브랜치 · 커밋을 하지 않는다. 코드를 바꿔야 하면 사람에게 묻는다.
            """
        }
    }

    /// 새 이슈 · 이어 하기 꼬리말 머리 — 명령 모양과 시작 전 확인. 모양은 `SessionSettings.repoGitAllow` 와 맞춘다
    /// (최종 리뷰 I-2: 모양을 안 대면 모델이 `git checkout main && git pull` · `gh pr list` 를 골라 권한 창에 멈춘다).
    private static let commands = """
        브랜치 · 커밋 · push · 이슈 · PR 을 만드는 git · gh 명령은 아래 단계에 적힌 모양 그대로 하나씩 친다. 뒤에 ; echo $? 나 파이프를 붙이지 않는다 — 붙이면 권한 창이 떠 멈춘다. 읽기(git log · git diff 등)는 필요한 대로 한다.
        시작하기 전에 git status --porcelain 을 본다. 커밋 안 한 변경이 있으면 건드리지 않고, 이 터미널에서 사람에게 어떻게 할지 묻고 기다린다.
        """

    /// 사람이 남긴 변경이 배분 커밋에 섞이지 않게.
    private static let addRule = "바꾼 파일만 git add <파일…> 로 올린다 — git add -A · git add . 는 쓰지 않는다."

    /// 본문의 백틱 · `$` 가 셸에서 풀리지 않게. heredoc 모양은 `gh … create *` 허용에 맞는다(실측).
    private static let bodyRule = "제목은 작은따옴표로 감싸고, 본문은 --body \"$(cat <<'EOF' … EOF)\" 처럼 작은따옴표 heredoc 으로 넘긴다 — 큰따옴표에 바로 넣으면 ` 와 $ 가 셸에서 풀린다."

    /// Codex 권한 규칙은 명령 치환 · heredoc 이 든 명령을 검사하지 않고 막는다 — 작은따옴표 인자만 쓴다.
    private static let codexBodyRule = "제목 · 본문은 각각 작은따옴표 한 덩어리로 넘긴다(본문은 여러 줄이어도 된다): --title '<제목>' --body '<본문>'. 안의 작은따옴표는 '\\'' 로 쓴다. 명령 치환이나 heredoc 을 쓰지 않는다 — 쓰면 권한 검사를 건너뛰어 막힌다."
    /// 이슈 #61 — 새 이슈 배분은 브랜치 이름을 페인이 정하므로 이유까지 적는다(예시는 `#` 이 든 이 사용자의 규칙 모양).
    private static let codexBranchRule = "브랜치 이름은 작은따옴표로 감싼다(예: git switch -c 'fix/#12/x' 'origin/main' · git push -u origin 'fix/#12/x') — 따옴표 밖에 # 이 있으면 권한 규칙을 건너뛰어 승인 창이 뜬다."
    private static let codexCommitRule = "git commit -m '<메시지>' 한 덩어리로(여러 줄 가능, 같은 인용 규칙) 넘긴다."

    /// 맨 `git push` · `HEAD` 는 기본 브랜치에서 승인 없이 나갈 수 있어 묻게 해 뒀다(`SessionSettings.repoGitAsk`).
    private static let pushRule = "push 는 브랜치 이름을 적은 그 모양만 쓴다 — 맨 git push 는 쓰지 않는다."

    /// 세 꼴이 같이 쓰는 꼬리 — waiting 안내와 ask_orchestrator.
    private static let common = """
        사람에게 묻거나 승인을 기다리느라 멈추는 것은 끝난 게 아니다 — 그때는 complete 를 부르지 않는다.
        레포 사이 판단이 막히면 ask_orchestrator 툴로 조율자에게 묻는다. 사람 승인이 필요한 일은 이 터미널에서 그대로 묻는다.
        """

    private static func blank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func relay(_ kind: RelayKind, seq: Int?, repoName: String, body: String, time: String) -> String {
        let head: String
        switch kind {
        case .completion: head = "배분 #\(seq ?? 0) 끝남 (\(time))"
        case .failure:    head = seq.map { "배분 #\($0) 실패 (\(time))" } ?? "실패 (\(time))"
        case .answerFailure: head = seq.map { "답 전달 실패 (배분 #\($0), \(time))" } ?? "답 전달 실패 (\(time))"
        case .report:     head = seq.map { "보고 (배분 #\($0), \(time))" } ?? "보고 (\(time))"
        case .question:   head = seq.map { "질문 (배분 #\($0), \(time))" } ?? "질문 (\(time))"
        case .limit:
            // 계정 단위 일이라 레포 이름을 달지 않는다(조율자 페인의 한도 실패면 레포가 없다).
            let limitHead = seq.map { "Codex 한도 (배분 #\($0), \(time))" } ?? "Codex 한도 (\(time))"
            return "[두레] \(limitHead)\n\(body)"
        }
        return "[두레] ‹\(repoName)› \(head)\n\(body)"
    }

    // MARK: - Codex 한도 (4단계, D-46)

    /// 한도가 찼을 때 조율자에게 가는 글. 조율자가 Codex 면 이 글도 풀린 뒤에 풀림 안내와 한 묶음으로 간다.
    static func limitNotice(until: Int, timeZone: TimeZone = .current) -> String {
        "Codex 사용 한도가 찼다. \(hourMinute(until, timeZone: timeZone)) 에 다시 확인한다 — Codex 페인 배분은 그때까지 큐에 쌓인다. "
            + "Claude 페인은 그대로 간다. 한도로 끊긴 배분은 실패로 닫지 않고, 풀리면 두레가 그 페인에 이어서 하라고 다시 보낸다."
    }

    /// 풀렸을 때 조율자에게 가는 글.
    static let limitReleased = "Codex 한도가 풀렸다 — 멈춘 배분을 다시 보낸다."

    /// Codex 조율자의 한도 실패 턴에서 되돌린 relay 를 다시 실은 묶음의 첫 줄.
    static let limitResent = "[두레] 앞 묶음 일부는 한도로 끊긴 턴에 넘긴 것을 다시 보낸다 — 이미 dispatch · answer 한 것은 tasks 로 확인하고 다시 하지 않는다."

    /// 한도로 끊긴 배분을 리셋 뒤 그 페인에 다시 보내는 글. 끊긴 턴이 첫 모델 호출에서 실패했으면 에이전트는 아무것도 안 했으므로
    /// **원래 배분 전문**을 다시 싣는다(j-stage4 2절). 이미 한 일이 있으면 그 뒤부터 하게 머리에 적는다.
    static func resumeAfterLimit(_ d: Dispatch, repoName: String, kind: AgentKind = .codex) -> String {
        """
        [두레] 배분 #\(d.seq) 이어 하기 — Codex 한도가 풀렸다
        앞 턴이 한도로 끊겼다 — 이어서 하라. 이미 한 일(이슈 · 브랜치 · 커밋 · PR)이 있으면 git status · git log 로 확인하고 그 뒤부터 한다. 이미 만든 이슈 · PR 을 다시 만들지 않는다.
        아래는 원래 배분 전문이다.

        \(dispatch(d, repoName: repoName, kind: kind))
        """
    }

    /// `H:mm`(예: 9:05 · 14:07). 테스트는 시간대를 넣는다.
    static func hourMinute(_ epoch: Int, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "H:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// 조율자의 답을 레포 페인이 받는 글로. 질문은 첫 줄만, 120자까지.
    static func answer(seq: Int?, question: String?, body: String) -> String {
        var lines = ["[두레] 조율자 답 (\(seq.map { "배분 #\($0)" } ?? "배분 없음"))"]
        if let q = question {
            let first = q.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            lines.append("질문: " + (first.count > 120 ? String(first.prefix(120)) + "…" : first))
        }
        lines.append(body)
        lines.append("")
        if let seq { lines.append("이 답대로 배분 #\(seq) 을 이어 간다. 다 끝나면 complete 를 부른다.") }
        lines.append("사람이 이 터미널에서 이미 다르게 답했으면 사람의 답을 따르고, 어긋난다고 짧게 알린다.")
        return lines.joined(separator: "\n")
    }

    /// 조율자가 안 떠 있는 동안 쌓인 것을 첫 프롬프트 하나로.
    static func bundle(_ parts: [String]) -> String {
        parts.joined(separator: "\n\n---\n\n")
    }
}
