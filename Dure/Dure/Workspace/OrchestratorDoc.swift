import Foundation

/// 이슈 #16 — 조율자의 지시문. 워크스페이스 폴더의 `CLAUDE.md` 로 쓰이고, 조율자의 cwd 라
/// claude 가 프로젝트 지시문으로 자동으로 읽는다.
///
/// **앱이 관리하고 조율자를 띄울 때마다 다시 쓴다** (`workspace.md` 와 같은 지위).
/// 사람의 지시는 `context.md` 에 쓴다 — 사람이 고친 지시문을 앱이 덮어쓰는 일이 없게 역할을 나눈다.
///
/// 메시지 범위·git 형태는 Claude Code 가 강제하지 못하는 규칙이라(D-31) **이 문서가 유일한 근거**다.
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
        필요하면 이슈 초안을 추천한다. **레포 코드를 고치지 않는다** — 각 레포 페인의 일이다.

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

        ## 다른 세션에 메시지 보내기

        보낼 때는 이름이 `\(sessionPrefix)` 로 시작하는 세션에만 보낸다 (이 워크스페이스의 레포 페인).
        다른 세션 — 다른 워크스페이스, 무관한 레포, 이 앱 밖의 Claude — 에는 보내지 않는다.
        이 맥의 모든 Claude 세션이 목록에 보이지만, 그것들은 이 작업과 상관없다.

        """
        return out
    }
}
