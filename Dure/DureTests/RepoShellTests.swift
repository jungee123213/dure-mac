import AppKit
import Foundation
import Testing
@testable import Dure

/// 이슈 #30 — 레포 경로로 iTerm 창 하나를 열고 닫는다. git 쓰기는 사람이 거기서 한다(ADR-4).
/// 실제 창을 띄우지 않도록 AppleScript 실행은 가짜로 바꾼다. 스크립트 문법만 진짜 컴파일러로 확인한다.
@MainActor
struct RepoShellTests {

    // MARK: - 스크립트

    /// 경로의 `'` 를 그대로 넣으면 `cd` 가 깨지고, `\` 를 AppleScript 문자열에 그대로 넣으면 컴파일이 깨진다.
    @Test func 열기_스크립트는_경로를_셸과_AppleScript_양쪽에서_이스케이프한다() {
        let s = RepoShellScript.open(.iTerm, path: "/x/it's dir")
        #expect(s.contains(#"write text " cd '/x/it'\\''s dir' && clear""#))
        #expect(s.contains(#"application id "com.googlecode.iterm2""#))
    }

    @Test func 터미널앱_열기_스크립트도_같은_cd_를_쓴다() {
        let s = RepoShellScript.open(.terminal, path: "/x/a b")
        #expect(s.contains(#"do script " cd '/x/a b' && clear""#))
        #expect(s.contains(#"application id "com.apple.Terminal""#))
    }

    /// 확인 · 닫기가 꺼져 있는 iTerm 을 깨우면 안 된다 — `tell` 은 앱을 띄운다.
    @Test func 확인과_닫기는_앱이_떠_있을_때만_말을_건다() {
        for s in [RepoShellScript.exists(.iTerm, windowID: 7), RepoShellScript.close(.iTerm, windowID: 7)] {
            #expect(s.contains(#"if application id "com.googlecode.iterm2" is running then"#))
            #expect(s.contains("window id 7"))
        }
    }

    /// 실측(iTerm2) — 닫은 창도 "닫기 되돌리기" 용으로 탭 0개 · 안 보이는 채 목록에 남아 `exists` 가 true 다.
    /// 탭이 있어야 열린 창이다. 이게 빠지면 직접 닫은 창이 영영 `닫기` 로 남는다.
    @Test func 확인은_탭이_남은_창만_있다고_본다() {
        #expect(RepoShellScript.exists(.iTerm, windowID: 7).contains("(count of tabs of window id 7) > 0"))
    }

    /// 이 맥에 설치된 앱의 용어집으로 실제 컴파일한다(실행은 안 함). 설치돼 있지 않으면 건너뛴다.
    @Test(arguments: [ShellApp.iTerm, .terminal])
    func 스크립트가_컴파일된다(app: ShellApp) throws {
        try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil)
        for source in [RepoShellScript.open(app, path: "/tmp"),
                       RepoShellScript.exists(app, windowID: 1),
                       RepoShellScript.close(app, windowID: 1)] {
            var error: NSDictionary?
            let ok = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
            #expect(ok, "\(error ?? [:])\n\(source)")
        }
    }

    @Test func iTerm_이_있으면_iTerm_없으면_터미널앱() {
        #expect(ShellApp.preferred(isInstalled: { _ in true }) == .iTerm)
        #expect(ShellApp.preferred(isInstalled: { $0 != ShellApp.iTerm.bundleID }) == .terminal)
    }

    // MARK: - 열기 · 닫기

    private let existing = Repo(id: "r1", workspaceId: "w", path: NSTemporaryDirectory())
    private let missing = Repo(id: "r2", workspaceId: "w", path: "/no/such/dure-repo")

    @Test func 열면_창_번호를_기억한다() {
        let runner = FakeScriptRunner(results: [.success("42")])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(existing)
        #expect(shells.isOpen(existing))
        #expect(runner.sources.count == 1)
        #expect(runner.sources[0] == RepoShellScript.open(.iTerm, path: existing.path))
    }

    /// 레포당 창은 하나 — 열려 있으면 버튼은 닫기다. 연 앱으로 닫는다(그 사이 기본 앱이 바뀌어도).
    @Test func 다시_누르면_연_앱의_그_창을_닫는다() {
        let runner = FakeScriptRunner(results: [.success("42"), .success("")])
        var app = ShellApp.iTerm
        let shells = RepoShells(runner: runner, preferredApp: { app })
        shells.toggle(existing)
        app = .terminal
        shells.toggle(existing)
        #expect(!shells.isOpen(existing))
        #expect(runner.sources.last == RepoShellScript.close(.iTerm, windowID: 42))
    }

    @Test func 폴더가_없으면_열지_않고_알린다() {
        let runner = FakeScriptRunner(results: [])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(missing)
        #expect(!shells.isOpen(missing))
        #expect(runner.sources.isEmpty)
        #expect(shells.problem?.contains("폴더") == true)
    }

    /// -1743 = 자동화 권한 거부. 어디서 켜는지 알려줘야 다시 누를 수 있다.
    @Test func 권한이_없으면_자동화_설정을_안내한다() {
        let runner = FakeScriptRunner(results: [.failure(AppleScriptError(number: -1743, message: "Not authorized"))])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(existing)
        #expect(!shells.isOpen(existing))
        #expect(shells.problem?.contains("자동화") == true)
    }

    @Test func 창_번호가_아닌_답이_오면_열린_것으로_치지_않는다() {
        let runner = FakeScriptRunner(results: [.success("")])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(existing)
        #expect(!shells.isOpen(existing))
        #expect(shells.problem != nil)
    }

    /// 사람이 iTerm 에서 직접 닫은 창은 두레로 돌아왔을 때 `열기` 로 돌아온다.
    @Test func 새로고침하면_사라진_창만_잊는다() {
        let other = Repo(id: "r3", workspaceId: "w", path: NSTemporaryDirectory())
        let runner = FakeScriptRunner(results: [.success("1"), .success("2"), .success("false"), .success("true")])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(existing)
        shells.toggle(other)
        shells.refresh()
        #expect(shells.isOpen(existing) != shells.isOpen(other))
        #expect(runner.sources.count == 4)
    }

    /// 확인이 실패하면(권한 등) 창이 없다고 단정하지 않는다 — 다음 누름이 닫기로 남아야 창이 고아가 되지 않는다.
    @Test func 확인이_실패하면_기억을_지우지_않는다() {
        let runner = FakeScriptRunner(results: [.success("1"), .failure(AppleScriptError(number: -1743, message: ""))])
        let shells = RepoShells(runner: runner, preferredApp: { .iTerm })
        shells.toggle(existing)
        shells.refresh()
        #expect(shells.isOpen(existing))
    }
}

/// 넘긴 스크립트를 적어 두고, 미리 정한 답을 차례로 돌려준다.
final class FakeScriptRunner: AppleScriptRunning {
    private var results: [Result<String, AppleScriptError>]
    private(set) var sources: [String] = []

    init(results: [Result<String, AppleScriptError>]) { self.results = results }

    func run(_ source: String) throws -> String {
        sources.append(source)
        guard !results.isEmpty else { Issue.record("예상하지 못한 스크립트 실행"); return "" }
        return try results.removeFirst().get()
    }
}
