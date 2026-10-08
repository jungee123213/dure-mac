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
                     "레포 페인에 일을 넘긴다. **사람이 배분안을 보고 '진행' 이라고 한 뒤에만** 부른다. 페인이 일하는 중이면 두레가 보관했다가 끝난 뒤 넣고, 안 떠 있으면 사람이 시작할 때 싣는다. 끝나면 '[두레] ‹레포› 배분 #N 끝남' 이 온다.",
                     props: ["repo": "레포 이름(workspace 툴에 나온 이름) 또는 경로",
                             "instruction": "그 레포가 할 일 전문. 받는 쪽은 이 글만 본다 — 맥락을 다 넣는다",
                             "title": "한 줄 제목(선택)"],
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
                tool("report",
                     "조율자에게 중간 보고를 올린다. 턴이 끝나면 마지막 답은 자동으로 올라가므로, 그 전에 알릴 것이 있을 때만.",
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
