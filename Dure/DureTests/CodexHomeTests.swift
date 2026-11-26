import Testing
import Foundation
@testable import Dure

struct CodexHomeTests {
    private let fm = FileManager.default

    /// 가짜 userHome 과 빈 대상 폴더를 임시 위치에 만든다.
    private func fixture() throws -> (base: URL, user: URL, dir: URL) {
        let base = fm.temporaryDirectory.appendingPathComponent("codexhome-\(UUID().uuidString)")
        let user = base.appendingPathComponent("user")
        try fm.createDirectory(at: user.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try fm.createDirectory(at: user.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "model = \"x\"\n".write(to: user.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "{}".write(to: user.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        try "secret".write(to: user.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "prefix_rule()\n".write(to: user.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        for n in ["app-server-control", "app-server-daemon", "ipc"] {
            try fm.createDirectory(at: user.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        return (base, user, base.appendingPathComponent("home"))
    }

    private func isLink(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    private func exists(_ u: URL) -> Bool { (try? u.checkResourceIsReachable()) == true || isLink(u) }
    private func config(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)
    }

    @Test func config_는_사본이고_cwd_신뢰_줄이_붙는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a b", userHome: f.user, into: f.dir)
        let c = f.dir.appendingPathComponent("config.toml")
        #expect(!isLink(c))
        let text = try config(f.dir)
        #expect(text.hasPrefix("model = \"x\"\n"))
        #expect(text.hasSuffix("[projects.\"/r/a b\"]\ntrust_level = \"trusted\"\n"))
    }

    @Test func 이미_신뢰된_cwd_는_다시_붙이지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try "[projects.\"/r/a\"]\ntrust_level = \"trusted\"\n".write(
            to: f.user.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        let text = try config(f.dir)
        #expect(text.components(separatedBy: "[projects.\"/r/a\"]").count - 1 == 1)
    }

    @Test func 점과_따옴표가_든_cwd_도_TOML_로_이스케이프된다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/foo.github.io", userHome: f.user, into: f.dir)
        #expect(try config(f.dir).contains("[projects.\"/r/foo.github.io\"]"))
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/it\"s\\x", userHome: f.user, into: f.dir)
        #expect(try config(f.dir).contains("[projects.\"/r/it\\\"s\\\\x\"]"))
    }

    @Test func hooks_json_은_가져오지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(!exists(f.dir.appendingPathComponent("hooks.json")))
    }

    @Test func 레포_페인은_사용자_규칙을_복사하고_조율자는_비운다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        let r = f.dir.appendingPathComponent("rules")
        #expect(!isLink(r))
        #expect(!isLink(r.appendingPathComponent("default.rules")))
        #expect(try String(contentsOf: r.appendingPathComponent("default.rules"), encoding: .utf8) == "prefix_rule()\n")
        try CodexHome.prepare(profile: .orchestrator, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(try fm.contentsOfDirectory(atPath: r.path).isEmpty)
        #expect(!isLink(r))
    }

    @Test func 레포_페인_home_에_dure_rules_를_쓴다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        let rules = f.dir.appendingPathComponent("rules/dure.rules")
        #expect(!isLink(rules))
        #expect(try String(contentsOf: rules, encoding: .utf8) == CodexGitPolicy.rulesFile())
        // 사용자 규칙도 그대로 같이 있다
        #expect(fm.fileExists(atPath: f.dir.appendingPathComponent("rules/default.rules").path))
    }

    @Test func 사용자에게_같은_이름의_dure_rules_가_있어도_두레_것이_이긴다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try "prefix_rule(pattern=[\"git\"], decision=\"allow\")\n"
            .write(to: f.user.appendingPathComponent("rules/dure.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(try String(contentsOf: f.dir.appendingPathComponent("rules/dure.rules"), encoding: .utf8)
                == CodexGitPolicy.rulesFile())
        // 사용자 파일은 건드리지 않는다
        #expect(try String(contentsOf: f.user.appendingPathComponent("rules/dure.rules"), encoding: .utf8)
                .hasPrefix("prefix_rule(pattern=[\"git\"]"))
    }

    @Test func 조율자_home_에는_dure_rules_가_없다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try CodexHome.prepare(profile: .orchestrator, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(!exists(f.dir.appendingPathComponent("rules/dure.rules")))
        #expect(try fm.contentsOfDirectory(atPath: f.dir.appendingPathComponent("rules").path).isEmpty)
    }

    @Test func 나머지는_사용자_home_으로_링크된다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        for n in ["auth.json", "sessions"] {
            let l = f.dir.appendingPathComponent(n)
            #expect(isLink(l))
            let dest = try fm.destinationOfSymbolicLink(atPath: l.path)
            #expect(dest.hasPrefix(f.user.path))
        }
    }

    @Test func 다시_준비하면_지난_내용이_남지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try "extra\n".write(to: f.dir.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(try String(contentsOf: f.dir.appendingPathComponent("rules/default.rules"), encoding: .utf8) == "prefix_rule()\n")
    }

    @Test func 다시_준비해도_서버가_home_안에_만든_실제_파일은_남긴다() throws {
        // 사용자 home 에 sessions 가 없던 때 준비하면 서버가 home 안에 실제 sessions/ 를 만든다 — 그것이 기록이다.
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try fm.removeItem(at: f.user.appendingPathComponent("sessions"))
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        let sessions = f.dir.appendingPathComponent("sessions")
        let rollout = sessions.appendingPathComponent("2026/11/19/rollout-1.jsonl")
        try fm.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}\n".write(to: rollout, atomically: true, encoding: .utf8)
        try "db".write(to: f.dir.appendingPathComponent("state_6.sqlite"), atomically: true, encoding: .utf8)
        // 서버 제어 폴더 · 두레가 만들지 않은 hooks.json 도 생겼다고 치자
        try fm.createDirectory(at: f.dir.appendingPathComponent("app-server-control"), withIntermediateDirectories: true)
        try "{}".write(to: f.dir.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)

        // 그 사이 사용자 home 에도 sessions · state_6.sqlite 가 생겼다
        try fm.createDirectory(at: f.user.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try "user-db".write(to: f.user.appendingPathComponent("state_6.sqlite"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)

        // 실제 항목은 그대로(링크로 바꾸지 않는다)
        #expect(!isLink(sessions))
        #expect(try String(contentsOf: rollout, encoding: .utf8) == "{}\n")
        #expect(!isLink(f.dir.appendingPathComponent("state_6.sqlite")))
        #expect(try String(contentsOf: f.dir.appendingPathComponent("state_6.sqlite"), encoding: .utf8) == "db")
        // 링크 · 서버 제어 폴더 · hooks.json 은 다시 맞춘다
        #expect(isLink(f.dir.appendingPathComponent("auth.json")))
        #expect(!exists(f.dir.appendingPathComponent("app-server-control")))
        #expect(!exists(f.dir.appendingPathComponent("hooks.json")))
        // 사용자 home 은 그대로
        #expect(try String(contentsOf: f.user.appendingPathComponent("state_6.sqlite"), encoding: .utf8) == "user-db")
    }

    @Test func 다시_준비하면_사용자_home_에서_사라진_링크는_지운다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(isLink(f.dir.appendingPathComponent("auth.json")))
        try fm.removeItem(at: f.user.appendingPathComponent("auth.json"))
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(!exists(f.dir.appendingPathComponent("auth.json")))
    }

    @Test func 링크된_규칙_파일은_내용을_복사한다() throws {
        // 링크째 복사하면 "다시 묻지 않기" 가 그 링크를 따라 사용자 전역 규칙에 쓰인다.
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let real = f.base.appendingPathComponent("elsewhere/shared.rules")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "shared_rule()\n".write(to: real, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: f.user.appendingPathComponent("rules/shared.rules"), withDestinationURL: real)
        try fm.createSymbolicLink(at: f.user.appendingPathComponent("rules/dangling.rules"),
                                  withDestinationURL: f.base.appendingPathComponent("nope.rules"))
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        let copy = f.dir.appendingPathComponent("rules/shared.rules")
        #expect(!isLink(copy))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "shared_rule()\n")
        try "appended\n".write(to: copy, atomically: false, encoding: .utf8)
        #expect(try String(contentsOf: real, encoding: .utf8) == "shared_rule()\n")
        // 끊어진 링크는 건너뛴다(페인 시작을 막지 않는다)
        #expect(!exists(f.dir.appendingPathComponent("rules/dangling.rules")))
    }

    @Test func remove_는_사용자_home_을_건드리지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        CodexHome.remove(f.dir)
        #expect(!exists(f.dir))
        #expect(fm.fileExists(atPath: f.user.appendingPathComponent("auth.json").path))
        #expect(fm.fileExists(atPath: f.user.appendingPathComponent("sessions").path))
    }

    @Test func 페인_home_경로는_페인_키에서_나온다() {
        let root = URL(fileURLWithPath: "/tmp/ch-root")
        #expect(CodexHome.url(forPaneKey: "repo:AB", root: root).path == "/tmp/ch-root/repo-AB")
        #expect(CodexHome.defaultRoot.path.hasSuffix("/.dure/codex-home"))
    }

    @Test func 서버_제어_폴더는_링크하지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        for n in ["app-server-control", "app-server-daemon", "ipc"] {
            #expect(!exists(f.dir.appendingPathComponent(n)))
        }
    }

    // MARK: - 이슈 #61 페인에서 고른 "다시 묻지 않기"

    private func rulesText(_ dir: URL, _ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("rules/\(name)"), encoding: .utf8)
    }
    private let gradle = #"prefix_rule(pattern=["./gradlew", "assembleDebug"], decision="allow")"#
    private let simctl = #"prefix_rule(pattern=["xcrun", "simctl"], decision="allow")"#

    /// 페인 안에서 (p) 를 고르면 Codex 가 `rules/default.rules` 에 줄을 더한다(spike E). 다시 준비해도 레포 페인 home 에 남는다.
    @Test func 페인에서_더한_규칙은_다시_준비해도_남는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try "prefix_rule()\n\(gradle)\n".write(to: f.dir.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(rulesText(f.dir, "default.rules") == "prefix_rule()\n")
        #expect(rulesText(f.dir, CodexHome.learnedRulesName) == "\(gradle)\n")
        // 사용자 전역 파일은 그대로다.
        #expect(try String(contentsOf: f.user.appendingPathComponent("rules/default.rules"), encoding: .utf8) == "prefix_rule()\n")
    }

    @Test func 배운_규칙은_쌓이고_같은_줄은_한_번만() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try "prefix_rule()\n\(gradle)\n".write(to: f.dir.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try "prefix_rule()\n\(gradle)\n\(simctl)\n".write(to: f.dir.appendingPathComponent("rules/default.rules"),
                                                         atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(rulesText(f.dir, CodexHome.learnedRulesName) == "\(gradle)\n\(simctl)\n")
    }

    /// 사용자가 전역 규칙에서 지운 줄은 페인 사본에 남아 있어도 페인에서 고른 것이 아니다 — 지난번에 넣은 사본과 비교한다.
    @Test func 사용자가_전역에서_지운_줄은_배운_것으로_옮기지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        let userRules = f.user.appendingPathComponent("rules/default.rules")
        try "prefix_rule()\n\(simctl)\n".write(to: userRules, atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        try "prefix_rule()\n".write(to: userRules, atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(rulesText(f.dir, CodexHome.learnedRulesName) == nil)
        #expect(rulesText(f.dir, "default.rules") == "prefix_rule()\n")
    }

    /// 이 기능 전에 만든 home 에는 지난 사본 기록이 없다 — 지금 사용자 파일을 기준으로 본다.
    @Test func 지난_사본_기록이_없는_옛_home_은_지금_사용자_파일을_기준으로() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try fm.createDirectory(at: f.dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try "prefix_rule()\n\(gradle)\n".write(to: f.dir.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(rulesText(f.dir, CodexHome.learnedRulesName) == "\(gradle)\n")
    }

    @Test func 조율자는_배우지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try CodexHome.prepare(profile: .orchestrator, cwd: "/w", userHome: f.user, into: f.dir)
        try "\(gradle)\n".write(to: f.dir.appendingPathComponent("rules/default.rules"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .orchestrator, cwd: "/w", userHome: f.user, into: f.dir)
        #expect(try fm.contentsOfDirectory(atPath: f.dir.appendingPathComponent("rules").path).isEmpty)
    }

    @Test func 사용자에게_같은_이름의_배운_규칙_파일이_있어도_가져오지_않는다() throws {
        let f = try fixture(); defer { try? fm.removeItem(at: f.base) }
        try "user\n".write(to: f.user.appendingPathComponent("rules/\(CodexHome.learnedRulesName)"), atomically: true, encoding: .utf8)
        try CodexHome.prepare(profile: .repoPane, cwd: "/r/a", userHome: f.user, into: f.dir)
        #expect(rulesText(f.dir, CodexHome.learnedRulesName) == nil)
    }
}
