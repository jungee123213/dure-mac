// Dure/DureTests/WorkUnitRulesTests.swift
import Foundation
import Testing
@testable import Dure

struct WorkUnitRulesTests {

    let utc = TimeZone(identifier: "UTC")!
    let ws = "/Users/me/.dure/workspaces"
    let ios = RepoInfo(root: "/r/ios", defaultBranch: "main", githubRepo: "Moa-Map/moamap-iOS")

    @Test func 하위_폴더에서도_레포_루트() {
        let roots: Set<String> = ["/r/ios/.git"]
        #expect(RepoRoot.findRoot(from: "/r/ios/MoaMap/Features", exists: roots.contains) == "/r/ios")
        #expect(RepoRoot.findRoot(from: "/Users/me/Desktop", exists: roots.contains) == nil)
    }

    @Test(arguments: [
        ("https://github.com/Moa-Map/moamap-android.git", "Moa-Map/moamap-android"),
        ("https://github.com/Moa-Map/moamap-iOS", "Moa-Map/moamap-iOS"),
        ("git@github.com:bookiibookii/bookiibookii-ios.git", "bookiibookii/bookiibookii-ios"),
        ("ssh://git@github.com/o/r.git\n", "o/r"),
    ])
    func 원격_주소(_ url: String, _ expected: String) {
        #expect(RepoRoot.githubRepo(fromRemote: url) == expected)
    }

    @Test func GitHub_아님과_기본_브랜치() {
        #expect(RepoRoot.githubRepo(fromRemote: "https://gitlab.com/o/r.git") == nil)
        #expect(RepoRoot.defaultBranch(fromSymbolicRef: "origin/dev\n") == "dev")
        #expect(RepoRoot.defaultBranch(fromSymbolicRef: nil) == nil)
    }

    @Test func 이슈_브랜치() {
        let p = WorkUnitRules.place(cwd: "/r/ios/MoaMap", branch: "feat/#52/splash", repo: ios, ts: 0, timeZone: utc, workspacesRoot: ws)
        #expect(p.kind == .issueBranch && p.repoRoot == "/r/ios" && p.issueNo == 52 && p.day == nil)
        #expect(p.key(generation: 0) == "issue_branch|/r/ios|feat/#52/splash|-|g0")
        #expect(p.baseKey == "issue_branch|/r/ios|feat/#52/splash|-")
    }

    @Test func 기본_브랜치는_날짜() {
        let p = WorkUnitRules.place(cwd: "/r/ios", branch: "main", repo: ios, ts: 1_791_594_000, timeZone: utc, workspacesRoot: ws)
        #expect(p.kind == .defaultBranch && p.day == "2026-10-10")
    }

    @Test(arguments: ["main", "master", "dev", "develop", "HEAD"])
    func 기본_브랜치를_모르면_흔한_이름(_ b: String) {
        let repo = RepoInfo(root: "/r/a", defaultBranch: nil, githubRepo: nil)
        #expect(WorkUnitRules.place(cwd: "/r/a", branch: b, repo: repo, ts: 0, timeZone: utc, workspacesRoot: ws).kind == .defaultBranch)
    }

    @Test func git_밖과_조율자() {
        let a = WorkUnitRules.place(cwd: "/Users/me/Desktop", branch: nil, repo: nil, ts: 0, timeZone: utc, workspacesRoot: ws)
        #expect(a.kind == .noGit && a.key(generation: 0) == "no_git|/Users/me/Desktop|-|1970-01-01|g0")
        let o = WorkUnitRules.place(cwd: "\(ws)/F9C2/", branch: nil, repo: nil, ts: 0, timeZone: utc, workspacesRoot: ws)
        #expect(o.kind == .orchestrator && o.workspaceId == "F9C2" && o.cwd == "\(ws)/F9C2")
    }

    @Test func 형제_폴더는_워크스페이스가_아니다() {
        #expect(WorkUnitRules.isUnderWorkspaces(cwd: "\(ws)/F9C2", workspacesRoot: ws))
        #expect(WorkUnitRules.isUnderWorkspaces(cwd: "\(ws)/F9C2", workspacesRoot: ws + "/"))
        #expect(!WorkUnitRules.isUnderWorkspaces(cwd: "\(ws)-old/F9C2", workspacesRoot: ws))
        let p = WorkUnitRules.place(cwd: "\(ws)-old/x", branch: nil, repo: nil, ts: 0, timeZone: utc, workspacesRoot: ws)
        #expect(p.kind == .noGit)
    }

    @Test(arguments: [("feat/#23/observer", 23), ("fix/#144/card", 144), ("main", nil), ("hotfix/#7-#9", 7)] as [(String, Int?)])
    func 이슈_번호(_ b: String, _ n: Int?) {
        #expect(WorkUnitRules.issueNumber(branch: b) == n)
    }

    @Test func 제외_경로() {
        let ex = ["/private/tmp/", "/Users/me/.dure/observer/"]
        #expect(WorkUnitRules.isExcluded(cwd: "/private/tmp/claude-501/x", prefixes: ex))
        #expect(WorkUnitRules.isExcluded(cwd: "/Users/me/.dure/observer/units/u1/runs/r1", prefixes: ex))
        #expect(!WorkUnitRules.isExcluded(cwd: "/Users/me/.dure/workspaces/w1", prefixes: ex))
    }

    // MARK: - 세대 (리뷰 P1-D)

    func unit(_ g: Int, merged: Int? = nil) -> WorkUnit {
        WorkUnit(id: "g\(g)", unitKey: "k\(g)", baseKey: "k", kind: .issueBranch, generation: g, mergedAt: merged, firstTs: 0, lastTs: 0)
    }

    @Test func 처음이면_세대_0() {
        #expect(WorkUnitRules.chooseGeneration([], turnTs: 5) == .new(0))
    }

    @Test func 머지_전이면_그_단위() {
        #expect(WorkUnitRules.chooseGeneration([unit(0)], turnTs: 5) == .existing(unit(0)))
    }

    @Test func 머지_뒤에_온_턴은_새_세대() {
        #expect(WorkUnitRules.chooseGeneration([unit(0, merged: 100)], turnTs: 150) == .new(1))
    }

    /// 늦게 수집된 옛 턴(머지 시각 이전)은 옛 단위로 간다 — 재수집 · 지연 수집과 다음 작업을 구분한다.
    @Test func 늦게_온_옛_턴은_옛_세대() {
        let units = [unit(1), unit(0, merged: 100)]     // 순서가 섞여 와도
        #expect(WorkUnitRules.chooseGeneration(units, turnTs: 90) == .existing(unit(0, merged: 100)))
        #expect(WorkUnitRules.chooseGeneration(units, turnTs: 150) == .existing(unit(1)))
    }
}
