// Dure/Dure/Observer/RepoRoot.swift
import Foundation

nonisolated struct RepoInfo: Equatable, Sendable {
    var root: String
    var defaultBranch: String?
    var githubRepo: String?
}

nonisolated protocol RepoResolving: Sendable {
    func info(forCwd cwd: String) -> RepoInfo?
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

/// 루트별로 한 번만 git 을 부른다.
nonisolated final class LiveRepoResolver: RepoResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var byRoot: [String: RepoInfo] = [:]

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
