// Dure/Dure/Observer/WorkUnitRules.swift
import Foundation

/// 턴 하나가 어느 작업 단위(추정 묶음)에 들어가는가. 스펙 v2 3-1. **순수 함수.**
nonisolated enum WorkUnitRules {

    /// 오래 사는 브랜치 — 날짜로 묶는다. **지금 ref 가 있는지 보지 않는다**: GitHub Flow 로 옮기며 `dev` 를
    /// 지운 레포도 트랜스크립트에는 과거 `dev` 턴이 남아 있다(이슈 #32, D-40). `HEAD` 는 복원 실패 · 진짜 detached.
    static let longLivedNames: Set<String> = ["main", "master", "dev", "develop", "development", "staging", "HEAD"]

    struct Placement: Equatable, Sendable {
        var kind: UnitKind
        var repoRoot: String?
        var cwd: String?
        var branch: String?
        var day: String?
        var issueNo: Int?
        var workspaceId: String?

        var baseKey: String { "\(kind.rawValue)|\(repoRoot ?? cwd ?? "-")|\(branch ?? "-")|\(day ?? "-")" }
        func key(generation: Int) -> String { WorkUnitRules.unitKey(baseKey: baseKey, generation: generation) }
    }

    /// 단위 열쇠 형식의 유일한 정의 — 수집이 새 세대를 만들 때와 머지 경계로 나눌 때가 같은 열쇠를 써야 한다.
    static func unitKey(baseKey: String, generation: Int) -> String { "\(baseKey)|g\(generation)" }

    static func place(cwd: String, branch: String?, repo: RepoInfo?, ts: Int, timeZone: TimeZone,
                      workspacesRoot: String) -> Placement {
        let wsPrefix = workspacesPrefix(workspacesRoot)
        if isUnderWorkspaces(cwd: cwd, workspacesRoot: workspacesRoot) {
            let id = cwd.dropFirst(wsPrefix.count).split(separator: "/").first.map(String.init) ?? ""
            return Placement(kind: .orchestrator, cwd: wsPrefix + id, day: day(ts, timeZone: timeZone), workspaceId: id)
        }
        guard let repo else {
            return Placement(kind: .noGit, cwd: (cwd as NSString).standardizingPath, day: day(ts, timeZone: timeZone))
        }
        let b = branch ?? "HEAD"
        let isDefault = longLivedNames.contains(b) || b == repo.defaultBranch
        if isDefault {
            return Placement(kind: .defaultBranch, repoRoot: repo.root, branch: b, day: day(ts, timeZone: timeZone))
        }
        return Placement(kind: .issueBranch, repoRoot: repo.root, branch: b, issueNo: issueNumber(branch: b))
    }

    private static func workspacesPrefix(_ root: String) -> String { root.hasSuffix("/") ? root : root + "/" }

    /// 조율자 cwd 판별의 유일한 정의 — Task 4 의 origin 도 이걸 쓴다.
    /// 끝에 "/" 를 붙여 비교하는 이유: `workspaces-old` 같은 형제 폴더가 접두사만 같다고 걸리면 안 된다.
    static func isUnderWorkspaces(cwd: String, workspacesRoot: String) -> Bool {
        cwd.hasPrefix(workspacesPrefix(workspacesRoot))
    }

    static func issueNumber(branch: String) -> Int? {
        guard let r = branch.range(of: #"#(\d+)"#, options: .regularExpression) else { return nil }
        return Int(branch[r].dropFirst())
    }

    static func isExcluded(cwd: String, prefixes: [String]) -> Bool { prefixes.contains { cwd.hasPrefix($0) } }

    static func day(_ ts: Int, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    enum GenerationChoice: Equatable, Sendable { case existing(WorkUnit), new(Int) }

    /// 같은 자리의 단위들 중, 머지 전이거나 턴 시각이 그 머지 시각 이전인 **가장 낮은 세대**.
    /// 없으면 새 세대 — 머지 뒤 이어 한 작업만 새 단위가 되고, 늦게 수집된 옛 턴은 옛 단위로 간다(리뷰 P1-D).
    static func chooseGeneration(_ units: [WorkUnit], turnTs: Int) -> GenerationChoice {
        let sorted = units.sorted { $0.generation < $1.generation }
        for u in sorted where u.mergedAt == nil || turnTs <= u.mergedAt! { return .existing(u) }
        return .new((sorted.last?.generation ?? -1) + 1)
    }
}
