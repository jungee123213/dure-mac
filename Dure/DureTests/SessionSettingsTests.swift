import Foundation
import Testing
@testable import Dure

/// 이슈 #16 · D-31 — 페인 종류별 `--settings`.
/// **급소 둘.** 레포 페인이 세션 간 메시지를 못 쓰는 것, 조율자의 git 허용이 읽기 명령에만 열리는 것.
struct SessionSettingsTests {

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func tempRoot() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dure-set-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - 레포 페인

    @Test func 레포_페인은_세션_간_메시지를_막는다() throws {
        let o = try Self.object(try SessionSettings.repoPaneJSON())
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String]
        #expect(deny == ["SendMessage", "ListAgents"])
    }

    /// #40 · 스펙 5-4b — 배분 페인이 이슈 · 브랜치 · 커밋 · push · PR 을 승인 창 없이 하고,
    /// 되돌리기 어려운 것(force push · 기본 브랜치 push · merge · rebase · reset --hard · 브랜치 삭제 · amend)은 묻는다.
    /// 규칙이 실제로 맞는지는 유닛 테스트가 아니라 실측(D-43)이 본다.
    @Test func 레포_페인은_git_쓰기를_허용하고_되돌리기_어려운_것은_묻는다() throws {
        let p = try #require(try Self.object(try SessionSettings.repoPaneJSON())["permissions"] as? [String: Any])
        let allow = p["allow"] as? [String] ?? []
        let ask = p["ask"] as? [String] ?? []
        #expect(allow == [SessionSettings.mcpAllowRule] + SessionSettings.repoGitAllow)
        #expect(ask == SessionSettings.repoGitAsk)
        #expect(ask.contains("Bash(gh pr merge *)"))
        #expect(ask.contains("Bash(git push --force *)"))
        #expect(!allow.contains { $0.contains("merge") || $0.contains("--force") || $0.contains("rebase") })
    }

    /// D-43 실측 — 시작값으로는 승인 없이 나갔던 모양들. 빠지면 다시 뚫린다.
    @Test func 레포_페인은_실측에서_뚫린_push_모양도_묻는다() {
        let ask = SessionSettings.repoGitAsk
        for rule in ["Bash(git push *:main)", "Bash(git push *:develop)", "Bash(git push *:master)",
                     "Bash(git push * +*)", "Bash(git push -d *)", "Bash(git push * :**)",
                     "Bash(git push *--mirror*)", "Bash(git switch -f*)", "Bash(git switch -C *)",
                     // 수정 1회차 — 첫 인자 force(`--force-with-lease=x …` · `-fu`), 뒤 인자 · 전체 이름 기본 브랜치
                     "Bash(git push --force*)", "Bash(git push -f*)",
                     "Bash(git push * main *)", "Bash(git push * develop *)", "Bash(git push * master *)",
                     "Bash(git push *refs/heads/main)", "Bash(git push *refs/heads/develop)",
                     "Bash(git push *refs/heads/master)"] {
            #expect(ask.contains(rule), "\(rule)")
        }
    }

    /// 최종 리뷰 I-1 — 규칙은 지금 브랜치를 못 본다. 기본 브랜치에 선 페인의 맨 `git push` · `HEAD` · `--all` · `--tags` 가
    /// 승인 없이 나가면 안 된다(#40 전에는 물었다). 배분 꼬리말은 `git push -u origin <브랜치>` 만 쓰게 한다.
    @Test func 레포_페인은_브랜치를_못_박은_push_도_묻는다() {
        let allow = SessionSettings.repoGitAllow
        let ask = SessionSettings.repoGitAsk
        #expect(!allow.contains("Bash(git push)"))
        // 재리뷰 — 막는 목록으로는 `git push origin` · `--no-verify` · `origin @` 같은 브랜치 없는 push 를 다 못 막는다.
        // 허용을 꼬리말의 유일한 push 모양으로 좁힌다. 나머지 push 는 예전처럼 묻는다.
        #expect(!allow.contains("Bash(git push *)"))
        #expect(allow.contains("Bash(git push -u origin *)"))
        #expect(allow.filter { $0.hasPrefix("Bash(git push") } == ["Bash(git push -u origin *)"])
        for rule in ["Bash(git push)", "Bash(git push -u origin)", "Bash(git push * HEAD)", "Bash(git push *--all*)", "Bash(git push *--tags*)",
                     "Bash(git push *:main *)", "Bash(git push *:develop *)", "Bash(git push *:master *)",
                     "Bash(git push *refs/heads/main *)", "Bash(git push *refs/heads/develop *)",
                     "Bash(git push *refs/heads/master *)"] {
            #expect(ask.contains(rule), "\(rule)")
        }
    }

    /// 꼬리말이 시키는 읽기 명령(`git status --porcelain`)도 승인 창 없이 돈다(실측).
    @Test func 레포_페인은_git_status_를_묻지_않는다() {
        #expect(!SessionSettings.repoGitAsk.contains { $0.contains("git status") })
    }

    /// 규칙 끝의 `:*` 는 옛 접두 문법으로 읽혀 glob 이 아니게 된다(실측: `Bash(git push * :*)` 가 `:x` 삭제를 못 잡았다).
    @Test func 레포_페인_규칙은_끝이_콜론_별이_아니다() {
        let rules = SessionSettings.repoGitAllow + SessionSettings.repoGitAsk
        #expect(!rules.contains { $0.hasSuffix(":*)") })
    }

    @Test func 레포_페인에도_훅이_들어간다() throws {
        let hooks = try Self.object(try SessionSettings.repoPaneJSON())["hooks"] as? [String: Any]
        #expect(Set(hooks?.keys.map { $0 } ?? []) == Set(HookBridge.hookEvents))
    }

    // MARK: - 조율자

    @Test func 조율자는_레포마다_읽기_명령_넷만_허용한다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/back", "/a/ios"]))
        let allow = (o["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(allow == [
            "Bash(git -C /a/back log *)", "Bash(git -C /a/back status *)",
            "Bash(git -C /a/back diff *)", "Bash(git -C /a/back show *)",
            "Bash(git -C /a/ios log *)", "Bash(git -C /a/ios status *)",
            "Bash(git -C /a/ios diff *)", "Bash(git -C /a/ios show *)",
            SessionSettings.mcpAllowRule,
        ])
    }

    /// D-31 — 중간 와일드카드와 `git -C:*` 는 쓰기·옵션 끼워 넣기를 연다.
    @Test func 넓은_규칙을_만들지_않는다() throws {
        let rules = SessionSettings.gitReadRules(repoPath: "/a/b")
        #expect(!rules.contains { $0.contains("-C *") || $0.contains("-C:") })
        #expect(rules.allSatisfy { $0.hasPrefix("Bash(git -C /a/b ") })
    }

    /// 단계 4 · D-32 — 배분 통로가 생겼으니 조율자도 맥 전체 세션에 보낼 이유가 없다. 범위는 소켓으로 강제된다.
    @Test func 조율자도_세션_간_메시지를_막는다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/b"]))
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(deny.contains("SendMessage") && deny.contains("ListAgents"))
        #expect(deny.contains("Bash(git -C /a/b *--output*)"))
    }

    /// 두레 툴 호출에 승인이 뜨면 배분마다 사람이 눌러야 한다(실측: allow 없으면 거부).
    @Test func 양쪽_다_두레_MCP_툴을_허용한다() throws {
        let repo = try Self.object(try SessionSettings.repoPaneJSON())
        let orch = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/b"]))
        for o in [repo, orch] {
            let allow = (o["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
            #expect(allow.contains("mcp__dure__*"))
        }
        // git 허용은 그대로 앞에 있다
        let allow = (orch["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.first == "Bash(git -C /a/b log *)")
    }

    /// D-31 후속 — diff·show·log 의 `--output=<파일>` 은 git 이 파일을 쓴다 (ADR-4).
    @Test func 조율자는_레포마다_output_옵션을_막는다() throws {
        let o = try Self.object(try SessionSettings.orchestratorJSON(repoPaths: ["/a/back", "/a/ios"]))
        let deny = (o["permissions"] as? [String: Any])?["deny"] as? [String]
        #expect(deny == ["Bash(git -C /a/back *--output*)", "Bash(git -C /a/ios *--output*)",
                         "SendMessage", "ListAgents"])
    }

    @Test func output_차단_규칙도_허용_규칙과_같은_경로_토큰을_쓴다() {
        let path = "/a/with space"
        #expect(SessionSettings.gitWriteDenyRules(repoPath: path)
                == ["Bash(git -C \(SessionSettings.gitPathToken(path)) *--output*)"])
    }

    /// Review Focus 2 — 공백·따옴표·한글 경로는 셸에서 인용된 모양으로 실행된다. 규칙도 그 모양이어야 맞는다.
    @Test(arguments: [
        ("/a/plain-dir_1.x", "/a/plain-dir_1.x"),
        ("/a/with space", "'/a/with space'"),
        ("/a/it's", "'/a/it'\\''s'"),
        ("/a/한글", "'/a/한글'"),
    ])
    func 경로_토큰은_셸_인용과_같다(_ path: String, _ token: String) {
        #expect(SessionSettings.gitPathToken(path) == token)
        #expect(SessionSettings.gitReadRules(repoPath: path).first == "Bash(git -C \(token) log *)")
    }

    // MARK: - 파일

    @Test func 조율자_설정은_워크스페이스_폴더_밖에_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try SessionSettings.writeOrchestrator("w1", repoPaths: ["/a/b"], root: root)
        #expect(url == root.appendingPathComponent("settings/orchestrator-w1.json"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!url.path.contains("/workspaces/"))
    }

    @Test func 레포_페인_설정_파일을_쓴다() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try SessionSettings.writeRepoPane(root: root)
        let data = try Data(contentsOf: SessionSettings.repoPaneURL(root: root))
        #expect((try Self.object(data)["permissions"] as? [String: Any]) != nil)
    }

    @Test func 감시자_묻기_설정은_훅이_없고_메시지를_막는다() throws {
        let o = try #require(try JSONSerialization.jsonObject(with: SessionSettings.observerJSON()) as? [String: Any])
        #expect(o["hooks"] == nil)
        #expect((o["permissions"] as? [String: Any])?["deny"] as? [String] == ["SendMessage", "ListAgents"])
    }
}
