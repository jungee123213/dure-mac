// Dure/DureTests/ReflogBranchTests.swift
import Foundation
import Testing
@testable import Dure

/// 이슈 #32 — `#` 이 든 브랜치는 트랜스크립트 `gitBranch` 가 "HEAD" 다. reflog 로 그 시각의 브랜치를 되살린다.
struct ReflogBranchTests {

    let sample = """
    HEAD@{1792662560}\tcommit: fix: x
    HEAD@{1792662555}\tpull --rebase origin main (finish): returning to refs/heads/feat/#30/open-in-iterm
    HEAD@{1792662554}\tpull --rebase origin main (pick): fix: x
    HEAD@{1792662553}\tpull --rebase origin main (start): checkout 3a2b1c0d
    HEAD@{1792662531}\tcheckout: moving from main to feat/#30/open-in-iterm
    HEAD@{1792662500}\tcheckout: moving from feat/#27/observer-accuracy to main
    """

    @Test func 전환만_시각_오름차순으로() {
        #expect(ReflogBranch.parse(sample).switches == [
            .init(ts: 1792662500, from: "feat/#27/observer-accuracy", to: "main"),
            .init(ts: 1792662531, from: "main", to: "feat/#30/open-in-iterm"),
            .init(ts: 1792662555, from: nil, to: "feat/#30/open-in-iterm"),
        ])
    }

    /// 실측: 16:12:11 에 옮기고 16:12:12 턴부터 "HEAD". 같은 초여도 옮긴 뒤로 본다.
    @Test func 같은_초면_전환이_먼저() {
        let s = ReflogBranch.parse(sample)
        #expect(ReflogBranch.branch(at: 1792662531, in: s) == "feat/#30/open-in-iterm")
        #expect(ReflogBranch.branch(at: 1792662532, in: s) == "feat/#30/open-in-iterm")
    }

    @Test func 같은_초의_전환_둘은_나중_것() {
        let s = ReflogBranch.parse("HEAD@{10}\tcheckout: moving from b to c\nHEAD@{10}\tcheckout: moving from a to b\n")
        #expect(ReflogBranch.branch(at: 10, in: s) == "c")
    }

    @Test func rebase_도중은_브랜치를_바꾸지_않는다() {
        #expect(ReflogBranch.branch(at: 1792662554, in: ReflogBranch.parse(sample)) == "feat/#30/open-in-iterm")
    }

    @Test func 첫_전환_이전이라도_기록_범위_안이면_출발지() {
        let log = ReflogBranch.parse("HEAD@{30}\tcheckout: moving from feat/#1/a to main\nHEAD@{20}\tcommit: x\n")
        #expect(ReflogBranch.branch(at: 25, in: log) == "feat/#1/a")
    }

    /// 리뷰 Important 1 — reflog 는 만료(90일)로 잘린다. 남은 기록보다 이전 턴은 알 수 없다.
    /// MoaMap 처럼 첫 전환이 `from feat/#124/…` 이면 옛 턴이 그 이슈 단위로 새어 들어간다.
    @Test func 기록보다_이전_시각은_nil() {
        let log = ReflogBranch.parse("HEAD@{30}\tcheckout: moving from feat/#124/x to main\nHEAD@{20}\tcommit: x\n")
        #expect(ReflogBranch.branch(at: 19, in: log) == nil)
        #expect(ReflogBranch.branch(at: 1792662000, in: ReflogBranch.parse(sample)) == nil)
    }

    @Test func 첫_전환이_rebase_종료면_그_브랜치() {
        let log = ReflogBranch.parse("HEAD@{30}\tpull --rebase origin main (finish): returning to refs/heads/feat/#2/b\nHEAD@{20}\tcommit: x\n")
        #expect(ReflogBranch.branch(at: 25, in: log) == "feat/#2/b")
    }

    @Test func 빈_reflog_는_nil() {
        #expect(ReflogBranch.branch(at: 1, in: ReflogBranch.parse("")) == nil)
    }

    @Test func 해시로_체크아웃하면_HEAD() {
        let s = ReflogBranch.parse("HEAD@{20}\tcheckout: moving from main to 3a2b1c0d9e8f\nHEAD@{10}\tcommit: x\n")
        #expect(ReflogBranch.branch(at: 21, in: s) == "HEAD")
        #expect(ReflogBranch.branch(at: 19, in: s) == "main")
    }

    @Test func 깨진_줄은_건너뛴다() {
        #expect(ReflogBranch.parse("garbage\nHEAD@{x}\tcheckout: moving from a to b\n").switches.isEmpty)
    }

    // MARK: - 실제 git (LiveRepoResolver)

    @discardableResult
    private func git(_ dir: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args)")
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepo() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflog-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(root, "init", "-q", "-b", "main")
        try git(root, "commit", "-q", "--allow-empty", "-m", "init")
        try git(root, "checkout", "-q", "-b", "feat/#1/x")
        return root
    }

    @Test func 실제_레포에서_지금_브랜치를_복원하고_바뀔_때만_다시_읽는다() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let r = LiveRepoResolver()
        let now = Int(Date().timeIntervalSince1970) + 1
        #expect(r.branch(atRoot: root, ts: now) == "feat/#1/x")
        #expect(r.branch(atRoot: root, ts: now) == "feat/#1/x")
        #expect(r.reflogReads == 1)
        try git(root, "checkout", "-q", "main")
        #expect(r.branch(atRoot: root, ts: now + 1) == "main")
        #expect(r.reflogReads == 2)
    }

    @Test func 레포가_없으면_nil() {
        #expect(LiveRepoResolver().branch(atRoot: "/nonexistent/\(UUID())", ts: 0) == nil)
    }
}
