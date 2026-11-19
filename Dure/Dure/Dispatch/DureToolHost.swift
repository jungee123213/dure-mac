import Foundation

/// 단계 4 — 툴 호출의 뜻. `MCPHandler` 가 이름·인자를 넘기면 여기서 `Dispatcher` 를 움직이고 **모델이 읽을 글**을 돌려준다.
/// 스토어가 아니라 `Context` 를 받는 이유는 메모리 DB 로 테스트하기 위해서다.
enum DureToolHost {

    struct Context {
        var workspaceID: String
        var repos: [Repo]
        /// 레포 페인이면 그 레포. 조율자면 nil.
        var repoID: String?
        var workspaceMarkdown: () -> String
        /// 그 레포에 페인을 띄울 수 있나. 폴더가 없는 레포에 배분하면 아무도 시작할 수 없어 큐에 영영 남는다.
        var canStart: (Repo) -> Bool = { $0.folderExists }
        /// 레포 id → 페인 상태 라벨. 안 떴으면 nil. `workspace` 툴의 큐 줄에 붙인다.
        var paneState: (String) -> String? = { _ in nil }
    }

    /// `tasks` 가 한 번에 돌려주는 최대 줄 수. 이력은 계속 쌓이므로 모델 컨텍스트를 이력으로 채우지 않게 자른다.
    static let tasksLimit = 30

    static func call(_ call: MCPToolCall, side: DureTools.Side, context ctx: Context,
                     dispatcher d: Dispatcher) -> MCPToolResult {
        // 소켓별 툴 집합이라 일어날 수 없지만, 방어적으로 — 레포 소켓에서 dispatch 가 오면 거부.
        guard DureTools.names(for: side).contains(call.name) else {
            return .init(text: "이 페인에서는 쓸 수 없는 툴이다: \(call.name)", isError: true)
        }
        do {
            switch call.name {
            case "dispatch":
                guard let repo = DureTools.resolveRepo(call.arguments["repo"] ?? "", in: ctx.repos) else {
                    return .init(text: "그런 레포가 없다: \(call.arguments["repo"] ?? ""). 이 워크스페이스의 레포: \(DureTools.repoCandidates(ctx.repos))", isError: true)
                }
                // 기록하지 않는다 — 큐에 넣으면 아무도 꺼내지 못한다.
                guard ctx.canStart(repo) else {
                    return .init(text: "레포 폴더가 없어 페인을 띄울 수 없다: \(repo.path). 사람에게 알려라.", isError: true)
                }
                let instruction = (call.arguments["instruction"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else { return .init(text: "instruction 이 비었다.", isError: true) }
                // 기록하기 전에 검증한다 — 거절된 호출은 이력에 남지 않는다.
                let git: DispatchGitRequest
                switch DispatchGit.request(from: call.arguments) {
                case .failure(let e): return .init(text: e.message, isError: true)
                case .success(let g): git = g
                }
                let title = call.arguments["title"].flatMap { $0.isEmpty ? nil : $0 }
                let out = try d.enqueue(workspaceID: ctx.workspaceID, repo: repo, title: title,
                                        instruction: instruction, git: git, toolUseId: call.toolUseId)
                // 배분 종류를 답에 싣는다 — 칸을 빠뜨려 git 없음으로 들어간 것을 조율자가 바로 알아챈다.
                let kind = switch git.mode {
                case .newIssue: "새 이슈"
                case .continueWork: "이어 하기"
                case nil: "git 없음"
                }
                let head = { (n: Int) in "#\(n) · \(repo.displayName) · \(kind)" }
                switch out {
                case .delivered(let n):
                    return .init(text: "\(head(n)) · 전달됨. 끝나면 '[두레] ‹\(repo.displayName)› 배분 #\(n) 끝남' 이 온다.")
                case .queuedBusy(let n):
                    return .init(text: "\(head(n)) · 큐 대기 — 페인이 일하는 중이라 끝난 뒤 전달된다.")
                case .queuedNotStarted(let n):
                    return .init(text: "\(head(n)) · 큐 대기 — 페인이 안 떠 있다. 사람이 그 페인을 시작하면 첫 프롬프트로 실린다. 사람에게 알려라.")
                case .deliveryFailed(let n, let attempts):
                    // 페인은 놀고 있는데 소켓 쓰기만 실패했다. 큐 대기라고 하면 조율자가 오지 않을 Stop 을 기다린다.
                    return .init(text: "\(head(n)) · 전달 실패(\(attempts)회) — 페인 소켓에 쓰지 못했다. 두레가 30초 안에 다시 시도한다. 3회 실패하면 실패로 닫고 알린다.")
                }
            case "answer":
                guard let repo = DureTools.resolveRepo(call.arguments["repo"] ?? "", in: ctx.repos) else {
                    return .init(text: "그런 레포가 없다: \(call.arguments["repo"] ?? ""). 이 워크스페이스의 레포: \(DureTools.repoCandidates(ctx.repos))", isError: true)
                }
                let answer = (call.arguments["answer"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { return .init(text: "answer 가 비었다.", isError: true) }
                let name = repo.displayName
                switch try d.answer(workspaceID: ctx.workspaceID, repo: repo, body: answer) {
                case .noQuestion:
                    return .init(text: "답할 질문이 없다. 일을 시키려면 dispatch 를 쓴다.", isError: true)
                case .delivered:
                    return .init(text: "\(name) 에 답을 전달했다.")
                case .queuedBusy:
                    return .init(text: "\(name) 페인이 일하는 중이라 이 턴이 끝나면 답이 간다.")
                case .queuedNotStarted:
                    return .init(text: "\(name) 페인이 안 떠 있다. 사람이 시작하면 답이 간다. 사람에게 알려라.")
                case .deliveryFailed(let attempts):
                    return .init(text: "\(name) 에 답 전달 실패(\(attempts)회) — 페인 소켓에 쓰지 못했다. 두레가 30초 안에 다시 시도한다. 3회 실패하면 실패로 닫고 알린다.")
                case .dispatchClosed(let seq):
                    return .init(text: "배분 #\(seq) 이 이미 닫혀 답을 전하지 못했다. 사람에게 알려라. 계속할 일이면 질문과 답을 instruction 에 넣어 dispatch 이어 하기로 보낸다.", isError: true)
                }
            case "workspace":
                var md = ctx.workspaceMarkdown()
                md += "\n## 배분 큐\n"
                for r in ctx.repos {
                    let n = d.queueCount(repoID: r.id)
                    md += "- \(r.displayName): 대기 \(n) · 상태 \(ctx.paneState(r.id) ?? "시작 대기")\n"
                }
                return .init(text: md)
            case "tasks":
                var rows = d.history(workspaceID: ctx.workspaceID)
                if let raw = call.arguments["state"], !raw.isEmpty {
                    guard let s = DispatchState(rawValue: raw) else {
                        return .init(text: "state 는 queued | delivered | waiting | done | failed | cancelled 중 하나다.", isError: true)
                    }
                    rows = rows.filter { $0.state == s }
                }
                guard !rows.isEmpty else { return .init(text: "배분 기록이 없다.") }
                let names = Dictionary(uniqueKeysWithValues: ctx.repos.map { ($0.id, $0.displayName) })
                // 이력은 최신순이다. 앞의 것만 보여주고 나머지는 개수로 알린다.
                let extra = max(0, rows.count - tasksLimit)
                var lines = rows.prefix(tasksLimit).map { r -> String in
                    let first = (r.result ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    let head = r.title ?? r.instruction.split(separator: "\n").first.map(String.init) ?? ""
                    // 응답 대기는 레포가 사람 답을 기다리는 것 — 조율자가 "끝났다" 로 읽지 않게 풀어 쓴다(이슈 #24).
                    let state = r.state == .waiting ? "waiting(응답 대기)" : r.state.rawValue
                    let git = DispatchPresentation.gitLine(r).map { " · \($0)" } ?? ""
                    return "- #\(r.seq) · \(names[r.repoId] ?? "?") · \(state) · \(head)" + git + (first.isEmpty ? "" : " → \(first)")
                }
                if extra > 0 { lines.append("(… 외 \(extra)건 — state 로 거르거나 대시보드에서)") }
                return .init(text: lines.joined(separator: "\n"))
            case "cancel":
                let ok = try d.cancel(DispatchRules.cancelRef(call.arguments["id"] ?? ""), workspaceID: ctx.workspaceID)
                return ok ? .init(text: "취소했다.") : .init(text: "큐에 있는 배분이 아니다(이미 전달됐거나 없다).", isError: true)
            case "complete":
                let summary = (call.arguments["summary"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { return .init(text: "summary 가 비었다.", isError: true) }
                guard let repoID = ctx.repoID, let seq = try d.complete(repoID: repoID, summary: summary,
                                                                           completion: DispatchGit.completion(from: call.arguments)) else {
                    return .init(text: "닫을 배분이 없다(두레 배분으로 받은 일이 아니거나 이미 닫혔다).", isError: true)
                }
                return .init(text: "배분 #\(seq) 을 완료로 닫고 조율자에게 올렸다.")
            case "report", "ask_orchestrator":
                let key = call.name == "report" ? "summary" : "question"
                let body = (call.arguments[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return .init(text: "\(key) 가 비었다.", isError: true) }
                // 지금 하고 있는 배분에 묶는다 — 조율자가 "배분 #N" 으로 알아보고, 대시보드 ④ 가 그 카드 밑에 그린다.
                try d.relay(workspaceID: ctx.workspaceID,
                            dispatchID: ctx.repoID.flatMap { d.outstandingDispatchID(repoID: $0) }, repoID: ctx.repoID,
                            kind: call.name == "report" ? .report : .question, body: body)
                return .init(text: call.name == "report"
                             ? "조율자에게 전달했다."
                             : "조율자에게 전달했다. 답은 이 터미널로 온다 — 조율자가 사람 승인을 받아 답한다. 그때까지 사람이 답할 수 있는 것은 사람에게 물어라.")
            default:
                return .init(text: "모르는 툴: \(call.name)", isError: true)
            }
        } catch {
            return .init(text: "두레 오류: \(error.localizedDescription)", isError: true)
        }
    }
}
