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
}
