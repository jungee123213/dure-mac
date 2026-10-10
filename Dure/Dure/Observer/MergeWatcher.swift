// Dure/Dure/Observer/MergeWatcher.swift
import Foundation

/// PR 머지 = 작업이 끝난 시점. 스펙 v2 3-3. **읽기만** — `gh pr list/view` · `git diff --shortstat`. `fetch` 없음(ADR-4).
nonisolated enum MergeWatcher {

    static let interval: TimeInterval = 600
    static let authScript = "gh auth status"

    struct Merge: Equatable, Sendable {
        var number: Int
        var url: String
        var mergedAt: Int
        var createdAt: Int?
        var head: String?
    }

    static func script(githubRepo: String, branch: String) -> String {
        "echo \(CommandOutput.marker); gh pr list -R \(Spawn.quoted(githubRepo)) --head \(Spawn.quoted(branch)) --state merged --json number,url,mergedAt,createdAt,headRefOid --limit 10"
    }

    static func parse(_ r: CommandResult) -> [Merge] {
        guard r.status == 0, !r.timedOut, let json = CommandOutput.afterMarker(r.stdout),
              let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let n = o["number"] as? Int, let m = (o["mergedAt"] as? String).flatMap(ObsParser.epoch) else { return nil }
            return Merge(number: n, url: o["url"] as? String ?? "", mergedAt: m,
                         createdAt: (o["createdAt"] as? String).flatMap(ObsParser.epoch), head: o["headRefOid"] as? String)
        }
    }

    /// 이 작업의 첫 턴 이후에 머지된 것 중 가장 이른 것. 같은 브랜치 이름의 옛 PR 은 고르지 않는다(리뷰 P1-D).
    static func choose(_ merges: [Merge], firstTs: Int) -> Merge? {
        merges.filter { $0.mergedAt >= firstTs }.min { $0.mergedAt < $1.mergedAt }
    }

    static func diffStatScript(_ u: WorkUnit) -> String? {
        if let pr = u.prNumber, let repo = u.githubRepo {
            return "echo \(CommandOutput.marker); gh pr view \(pr) -R \(Spawn.quoted(repo)) --json additions,deletions,changedFiles"
        }
        guard u.kind == .issueBranch, let root = u.repoRoot, let b = u.branch else { return nil }
        let r = Spawn.quoted(root)
        return "echo \(CommandOutput.marker); git -C \(r) diff --shortstat \"$(git -C \(r) symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo main)\"...\(Spawn.quoted(b))"
    }

    static func parseDiffStat(_ r: CommandResult) -> String? {
        guard r.status == 0, !r.timedOut, let body = CommandOutput.afterMarker(r.stdout) else { return nil }
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] {
            return "\(o["changedFiles"] as? Int ?? 0) files changed, \(o["additions"] as? Int ?? 0) insertions(+), \(o["deletions"] as? Int ?? 0) deletions(-)"
        }
        return t.contains("changed") ? t : nil
    }

    static func lines(fromStat s: String) -> Int? {
        func number(before word: String) -> Int? {
            guard let r = s.range(of: #"(\d+) "# + word, options: .regularExpression) else { return nil }
            return Int(s[r].split(separator: " ").first ?? "")
        }
        let ins = number(before: "insertion"), del = number(before: "deletion")
        if ins == nil && del == nil { return nil }
        return (ins ?? 0) + (del ?? 0)
    }
}
