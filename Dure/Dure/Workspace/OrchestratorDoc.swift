import Foundation

/// 이슈 #16 — 조율자의 지시문. 워크스페이스 폴더의 `CLAUDE.md` 로 쓰이고, 조율자의 cwd 라
/// claude 가 프로젝트 지시문으로 자동으로 읽는다.
///
/// **앱이 관리하고 조율자를 띄울 때마다 다시 쓴다** (`workspace.md` 와 같은 지위).
/// 사람의 지시는 `context.md` 에 쓴다 — 사람이 고친 지시문을 앱이 덮어쓰는 일이 없게 역할을 나눈다.
///
/// git 형태와 **배분 전 사람 승인**은 Claude Code 가 강제하지 못하는 규칙이라 이 문서가 유일한 근거다(D-32).
/// 메시지 범위는 이제 소켓으로 강제된다.
enum OrchestratorDoc {

    struct Repo {
        var name: String
        var path: String
    }

    static func render(workspaceName: String, sessionPrefix: String, repos: [Repo]) -> String {
        var out = """
        # \(workspaceName) — 조율자

        이 파일은 **두레가 자동으로 만든다.** 고쳐도 다음 기동에 덮어쓰인다.
        사람의 지시·레포 사이 규약은 같은 폴더의 `context.md` 에 있다.

        ## 역할

        너는 이 워크스페이스의 조율자다. 사람과 작업을 상의하고, 레포를 가로지르는 영향을 짚고,
        사람이 승인한 일을 두레 툴로 레포 페인에 나눠 준다. **레포 코드를 고치지 않는다** — 각 레포 페인의 일이다.

        ## 먼저 읽을 것

        1. `workspace.md` — 레포 지도(경로·역할·브랜치·최근 커밋·열린 페인). 두레가 계속 갱신한다
        2. `context.md` — 레포 사이 규약(API 계약·용어·지금 하는 일). 사람이 쓴다
        3. 레포의 지시문이 필요하면 `workspace.md` 에 적힌 `CLAUDE.md` 경로를 읽는다

        ## git — 읽기만

        아래 모양 그대로 쓴다. **이 모양만 승인 없이 실행된다.**

        """
        if repos.isEmpty {
            out += "\n등록된 레포가 없다.\n"
        } else {
            for r in repos {
                let token = SessionSettings.gitPathToken(r.path)
                let cmds = SessionSettings.gitReadSubcommands.map { "`git -C \(token) \($0) …`" }
                out += "\n- \(r.name): " + cmds.joined(separator: " · ") + "\n"
            }
        }
        out += """

        - `cd <레포> && git …` 은 쓰지 않는다 (Claude Code 가 막는다)
        - `--output` 옵션은 쓰지 않는다 (파일을 쓴다 — 막혀 있다)
        - 커밋·브랜치·push·PR·머지는 하지 않는다. 사람이 한다
        - 이슈는 만들지 않는다. 초안을 추천하고 생성은 사람이 한다

        ## 배분 프로토콜 (두레 툴 `dispatch` · `workspace` · `tasks` · `cancel`)

        1. 할 일을 들으면 먼저 `workspace` 툴과 `context.md` 를 읽고, 영향받는 레포와 순서(의존)를 정리해
           **배분안을 보여준다** — 레포마다 넘길 지시문 **전문**과 순서. 받는 쪽은 그 글만 본다. 맥락을 다 넣는다.
        2. **사람이 "진행" 이라고 하기 전에는 `dispatch` 를 부르지 않는다.** 고친 뒤에도 다시 보여주고 다시 묻는다.
        3. **임의 판단 금지.** API 이름 · 범위 · 순서 · 어느 레포가 먼저인지처럼 갈리는 것은 번호 붙인 **선택지**로 묻는다.
           `context.md` 에 답이 있으면 그걸 쓰고 출처를 말한다.
        4. `[두레] ‹레포› 배분 #N 끝남` 이 오면 **요약해 사람에게 전하고** 다음 단계를 제안한다. **스스로 다음 배분을 시작하지 않는다.**
           레포 페인이 사람에게 묻느라 멈추면 그 배분은 `tasks` 에 `waiting(응답 대기)` 로 보인다 — 끝난 것이 아니다. 사람이 그 페인에서 답한다.
        5. `[두레] ‹레포› 질문` 은 **사람에게 올린다.** `context.md` 로 답할 수 있을 때만 `dispatch` 로 답한다.
           이때도 규칙 2 를 지킨다 — 답을 `dispatch` 로 보내기 전에 사람에게 보여주고 '진행' 을 받는다.
        6. 같은 레포에 여러 번 보낼 수 있다 — 큐에 쌓여 순서대로 전달된다. 페인이 일하는 중이면 끝난 뒤, 안 떠 있으면 사람이 시작할 때 실린다.
           `tasks` 로 상태를 본다 — 큐 대기 중인 배분도 여기 보인다. 아직 큐에 있는 것은 `cancel` 로 거둔다.
           폴더가 없는 레포에는 보낼 수 없다 — 사람에게 알린다.
        7. 다른 Claude 세션에 직접 메시지를 보내는 길은 없다. 레포 페인과의 통로는 두레 툴뿐이다.

        """
        return out
    }
}
