import Foundation

/// 단계 4 — 두레가 페인에 주는 MCP 툴. **소켓이 곧 신원**이라 조율자 소켓은 조율자 툴만, 레포 소켓은 레포 툴만 본다.
/// 설명(description)은 모델이 읽는 글이다 — 언제 쓰는지를 적는다.
enum DureTools {

    /// 권한 규칙 `mcp__dure__*` 와 맞아야 한다.
    static let serverName = "dure"

    enum Side { case orchestrator, repo }

    static func names(for side: Side) -> [String] {
        definitions(for: side).compactMap { $0["name"] as? String }
    }

    static func definitions(for side: Side) -> [[String: Any]] {
        switch side {
        case .orchestrator:
            return [
                tool("dispatch",
                     "레포 페인에 일을 넘긴다. **사람이 배분안을 보고 '진행' 이라고 한 뒤에만** 부른다. 페인이 일하는 중이면 두레가 보관했다가 끝난 뒤 넣고, 안 떠 있으면 사람이 시작할 때 싣는다. 끝나면 '[두레] ‹레포› 배분 #N 끝남' 이 온다.\n\n배분 종류는 셋 중 하나다. 새 작업이면 issue_title + issue_body 를 준다(페인이 이슈를 등록하고 그 번호로 브랜치를 딴다). 기존 이슈 · 브랜치에 이어서 하는 일(보완 · 기기 확인 뒤 수정 · PR 리뷰 반영)이면 issue + branch 를 준다. 코드를 안 바꾸는 일이면 이 칸들을 모두 비운다. 이슈 초안은 배분안에서 사람에게 보여준 그대로 넣는다 — 고쳐 쓰지 않는다. git_scope 는 기본 commit(커밋까지)이고, 사람이 PR 까지 원했을 때만 pr 로 준다.",
                     props: ["repo": "레포 이름(workspace 툴에 나온 이름) 또는 경로",
                             "instruction": "그 레포가 할 일 전문. 받는 쪽은 이 글만 본다 — 맥락을 다 넣는다",
                             "title": "한 줄 제목(선택)",
                             "issue_title": "새 이슈 배분 — 이슈 초안 제목. 레포 이슈 템플릿 형식(예: [FEAT] …). 이어 하기와 함께 줄 수 없다",
                             "issue_body": "새 이슈 배분 — 이슈 초안 본문 전문(레포 템플릿 섹션 그대로). issue_title 이 있으면 필수, issue_title 없이 주면 거절",
                             "issue": "이어 하기 배분 — 이어 갈 기존 이슈 번호(165 또는 #165). branch 도 함께 준다",
                             "branch": "새 이슈면 브랜치 이름 제안(번호 자리는 #N, 예: feat/#N/share-button, 없으면 페인이 정한다). 이어 하기면 이어 쓸 기존 브랜치(필수)",
                             "base": "새 이슈 브랜치를 딸 기준 브랜치(선택). 머지 안 된 다른 브랜치에 기댈 때만. 없으면 레포 기본 브랜치 최신. 이어 하기에는 쓰지 않는다",
                             "git_scope": "commit(기본, 커밋까지) 또는 pr(PR 까지). git 을 안 쓰는 배분이면 무시된다"],
                     required: ["repo", "instruction"]),
                tool("workspace",
                     "워크스페이스 지도 — 레포 · 역할 · 경로 · 브랜치 · 최근 커밋 · 페인 상태 · 큐 길이. 배분안을 만들기 전에 읽는다.",
                     props: [:], required: []),
                tool("tasks",
                     "이 워크스페이스의 배분 이력(#번호 · 레포 · 상태 · 결과 첫 줄). 무엇이 큐에 있고 무엇이 끝났는지 볼 때.",
                     props: ["state": "queued | delivered | done | failed | cancelled 중 하나(선택). 없으면 전부"],
                     required: []),
                tool("cancel",
                     "아직 큐에 있는 배분을 취소한다. 이미 전달된 것은 취소할 수 없다.",
                     props: ["id": "배분 번호(#7 또는 7) 또는 id"], required: ["id"]),
            ]
        case .repo:
            return [
                tool("complete",
                     "두레 배분으로 받은 일을 **다 끝냈을 때만** 부른다. 새 이슈 · 이어 하기 배분이면 issue · branch (PR 을 열었으면 pr) 를 넣는다. 결과를 조율자에게 올리고 배분을 닫는다. 사람에게 묻거나 승인을 기다리느라 멈추는 것은 끝난 게 아니다 — 그때는 부르지 않는다.",
                     props: ["summary": "결과 요약(한 문단). 무엇을 바꿨고 무엇이 남았는지",
                             "issue": "만든(또는 이어 간) 이슈 번호(165 또는 #165). 새 이슈 · 이어 하기 배분이면 넣는다",
                             "branch": "실제로 쓴 브랜치 이름. 새 이슈 · 이어 하기 배분이면 넣는다",
                             "pr": "PR 을 열었으면 그 번호 또는 URL"],
                     required: ["summary"]),
                tool("report",
                     "조율자에게 중간 보고를 올린다. 일이 끝났으면 이것이 아니라 complete 를 쓴다.",
                     props: ["summary": "보고 내용"], required: ["summary"]),
                tool("ask_orchestrator",
                     "레포 사이 판단(API 이름 · 범위 · 순서)이 막힐 때 조율자에게 묻는다. 답은 이 터미널로 온다. 사람 승인이 필요한 일은 이 툴이 아니라 이 터미널에서 묻는다.",
                     props: ["question": "질문"], required: ["question"]),
            ]
        }
    }

    private static func tool(_ name: String, _ description: String,
                             props: [String: String], required: [String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (k, d) in props { properties[k] = ["type": "string", "description": d] }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    // MARK: - 레포 찾기 (Review Focus 4)

    /// 조율자는 `workspace.md` 의 표시 이름을 쓰지만 "Android" · 폴더명 · 경로로 부를 수도 있다. 전부 받는다.
    static func resolveRepo(_ query: String, in repos: [Repo]) -> Repo? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return repos.first { r in
            [r.displayName, r.label ?? "", (r.path as NSString).lastPathComponent, r.path]
                .contains { $0.lowercased() == q }
        }
    }

    static func repoCandidates(_ repos: [Repo]) -> String {
        repos.map { "\($0.displayName) (\($0.path))" }.joined(separator: " · ")
    }
}
