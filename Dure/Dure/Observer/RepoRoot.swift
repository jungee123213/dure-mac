// Dure/Dure/Observer/RepoRoot.swift
import Foundation

nonisolated struct RepoInfo: Equatable, Sendable {
    var root: String
    var defaultBranch: String?
    var githubRepo: String?
}

nonisolated protocol RepoResolving: Sendable {
    func info(forCwd cwd: String) -> RepoInfo?
    /// 시각 `ts` 에 그 레포가 어느 브랜치였나(reflog). 모르면 `nil`. 이슈 #32.
    func branch(atRoot root: String, ts: Int) -> String?
}

extension RepoResolving {
    func branch(atRoot root: String, ts: Int) -> String? { nil }
}

/// cwd → 레포. **git 읽기만**(ADR-4) — `symbolic-ref` · `remote get-url`. `fetch` 는 하지 않는다.
nonisolated enum RepoRoot {

    static func findRoot(from cwd: String, exists: (String) -> Bool) -> String? {
        var p = (cwd as NSString).standardizingPath
        while !p.isEmpty {
            if exists((p as NSString).appendingPathComponent(".git")) { return p }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p { return nil }
            p = parent
        }
        return nil
    }

    static func githubRepo(fromRemote raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            if s.hasSuffix(".git") { s.removeLast(4) }
            let parts = s.split(separator: "/")
            return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
        }
        return nil
    }

    static func defaultBranch(fromSymbolicRef s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.hasPrefix("origin/") ? String(t.dropFirst("origin/".count)) : t
    }
}

/// 루트별로 한 번만 git 을 부른다. reflog 는 파일이 바뀔 때만 다시 읽는다 — 수집 틱마다 git 을 띄우지 않게.
nonisolated final class LiveRepoResolver: RepoResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var byRoot: [String: RepoInfo] = [:]

    private struct Reflog {
        var mtime: Date
        var size: Int
        var log: ReflogBranch.Log
    }
    /// 루트 → reflog 파일 경로. 워크트리는 gitdir 아래라 git 에 한 번 묻는다. 못 구하면 `nil` 로 기억한다.
    private var logPaths: [String: String?] = [:]
    private var reflogs: [String: Reflog] = [:]
    /// `git reflog` 를 실제로 실행한 횟수(테스트용).
    private(set) var reflogReads = 0

    func branch(atRoot root: String, ts: Int) -> String? {
        guard let path = logPath(root),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        if let hit = lock.withLock({ reflogs[root] }), hit.mtime == mtime, hit.size == size {
            return ReflogBranch.branch(at: ts, in: hit.log)
        }
        guard let text = git(["reflog", "--date=unix", "--format=%gd%x09%gs"], at: root) else { return nil }
        let log = ReflogBranch.parse(text)
        lock.withLock {
            reflogs[root] = Reflog(mtime: mtime, size: size, log: log)
            reflogReads += 1
        }
        return ReflogBranch.branch(at: ts, in: log)
    }

    private func logPath(_ root: String) -> String? {
        if let hit = lock.withLock({ logPaths[root] }) { return hit }
        let raw = git(["rev-parse", "--git-path", "logs/HEAD"], at: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = raw.flatMap { $0.isEmpty ? nil : ($0.hasPrefix("/") ? $0 : (root as NSString).appendingPathComponent($0)) }
        lock.withLock { logPaths[root] = .some(path) }
        return path
    }

    func info(forCwd cwd: String) -> RepoInfo? {
        guard let root = RepoRoot.findRoot(from: cwd, exists: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        if let hit = lock.withLock({ byRoot[root] }) { return hit }
        let info = RepoInfo(root: root,
                            defaultBranch: RepoRoot.defaultBranch(fromSymbolicRef: git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], at: root)),
                            githubRepo: git(["remote", "get-url", "origin"], at: root).flatMap(RepoRoot.githubRepo))
        lock.withLock { byRoot[root] = info }
        return info
    }

    private func git(_ args: [String], at path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
