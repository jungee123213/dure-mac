import Foundation

/// `workspace.md` 를 만든다. 설계문서 4절.
///
/// **순수 함수만 둔다** — 파일도 DB 도 없이 문서 모양을 테스트하기 위해서다
/// (`TranscriptParser` 와 같은 이유).
///
/// 이 문서는 사람이 아니라 **조율자가 읽는다.** 그래서 "모르는 것" 과 "없는 것" 을
/// 구별해서 적는다 — git 을 못 읽은 것을 `clean` 으로 적으면 조율자가 변경이 없다고
/// 읽어버린다 (D-13).
///
/// **`nonisolated` 를 붙이지 않는다** — `AgentKind` 가 MainActor 라 참조에서 경고가 난다.
/// 순수 함수지만 메인에서 불려도 비용이 없다.
enum WorkspaceDoc {

    struct RepoLine {
        var name: String
        var path: String
        /// 없으면 줄을 생략한다.
        var role: String?
        /// nil 이면 읽지 못한 것이다. `clean` 과 다르다.
        var git: GitStatus?
        /// 지금 페인이 열려 있다면 어떤 CLI 인지. nil 이면 안 열려 있다.
        var openedWith: AgentKind?
        /// #16 — 레포 `CLAUDE.md` 경로(있을 때). 조율자는 이걸 자동으로 싣지 않고 필요할 때 읽는다(D-31 ②).
        var instructionsPath: String? = nil
        /// #16 — 이 레포 페인의 `claude --name`. 조율자가 메시지 대상을 찾을 때 쓴다.
        var sessionName: String? = nil
        /// #16 — 등록된 폴더가 없다(이슈 #10). 조율자가 없는 경로를 읽으려 하지 않게.
        var folderMissing: Bool = false
    }

    struct OrchestratorLine {
        var sessionName: String
        var openedWith: AgentKind?
    }

    static func render(name: String, repos: [RepoLine],
                       orchestrator: OrchestratorLine? = nil) -> String {
        var out = """
        # \(name)

        이 파일은 **두레가 자동으로 만든다.** 고쳐도 다음 갱신에 덮어쓰인다.
        사람이 쓰는 문서는 같은 폴더의 `context.md` 다.

        """

        if let o = orchestrator {
            out += "\n## 조율자\n\n- 세션 이름: `\(o.sessionName)`\n"
            out += o.openedWith.map { "- 지금 열려 있음 (\($0.rawValue))\n" } ?? "- 닫혀 있음\n"
        }

        guard !repos.isEmpty else {
            return out + "\n등록된 레포가 없습니다.\n"
        }

        out += "\n## 레포\n"
        for repo in repos {
            out += "\n### \(repo.name)\n\n"
            out += "- 경로: `\(repo.path)`\n"
            if repo.folderMissing { out += "- ⚠️ 폴더 없음 — 등록된 경로에 폴더가 없다\n" }
            if let role = repo.role, !role.isEmpty {
                out += "- 역할: \(role)\n"
            }
            if let p = repo.instructionsPath { out += "- 지시문: `\(p)`\n" }
            if let n = repo.sessionName { out += "- 세션 이름: `\(n)`\n" }
            out += "- 상태: \(statusLine(repo.git))\n"
            if let kind = repo.openedWith {
                out += "- 지금 페인이 열려 있음 (\(kind.rawValue))\n"
            }
            if let commits = repo.git?.recentCommits, !commits.isEmpty {
                out += "- 최근 커밋:\n"
                for c in commits { out += "    - \(c)\n" }
            }
        }
        return out
    }

    private static func statusLine(_ git: GitStatus?) -> String {
        guard let git else { return "git 상태를 읽지 못함" }
        let branch = git.isDetached ? "detached HEAD" : git.branch
        return git.isClean ? "\(branch) · clean"
                           : "\(branch) · 변경 \(git.dirtyCount)개"
    }
}
