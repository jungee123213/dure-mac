// Dure/Dure/Observer/Signals.swift
import Foundation

/// 다이제스트 4절의 계산값. **순수 함수** — 평가자가 근거로 삼는 숫자다.
nonisolated enum Signals {

    static let delayThreshold = 10
    /// 오래 걸려도 이상하지 않은 툴 — 지연으로 세지 않는다.
    static let notDelay: Set<String> = ["WebFetch", "WebSearch", "Agent", "Task",
                                         // 사람의 답을 기다리는 툴 — 오래 걸리는 게 정상이다(질문 · 계획 승인)
                                         "AskUserQuestion", "ExitPlanMode"]
    static let longRunning = ["xcodebuild", "./gradlew", "gradlew", "swift build", "swift test", "npm ", "pnpm ",
                              "yarn ", "pytest", "make", "sleep", "git push", "gh pr", "gh run", "pod ",
                              "xcrun simctl", "claude "]

    struct Count: Equatable, Sendable { var label: String; var count: Int }
    struct Delay: Equatable, Sendable { var label: String; var count: Int; var seconds: Int }
    struct Failure: Equatable, Sendable { var tool: String; var target: String; var error: String; var count: Int }

    /// 표시용 라벨. **allow 규칙 모양이 아니다**(리뷰 P1-G).
    static func label(_ t: ObsTool) -> String {
        if t.name == "Bash" { return "Bash(\((t.target ?? "").split(separator: " ").first.map(String.init) ?? ""))" }
        if t.name == "Skill" { return "Skill(\(t.target ?? ""))" }
        if t.name.hasPrefix("mcp__") { return "mcp:\(t.name.components(separatedBy: "__").dropFirst().first ?? "?")" }
        return t.name
    }

    /// 원인 미확인 지연 — 승인 · 네트워크 · 실행 중 무엇인지 모른다. 승인 시간이라고 부르지 않는다.
    static func isUnexplainedDelay(_ t: ObsTool) -> Bool {
        guard let r = t.resultTs, r - t.startedTs > delayThreshold, !notDelay.contains(t.name) else { return false }
        if t.name == "Bash" {
            let c = t.target ?? ""
            return !longRunning.contains { c.hasPrefix($0) || c.contains("&& \($0)") }
        }
        return true
    }

    static func delays(_ tools: [ObsTool], limit: Int = 10) -> [Delay] {
        var by: [String: Delay] = [:]
        for t in tools where isUnexplainedDelay(t) {
            let l = label(t)
            var d = by[l] ?? Delay(label: l, count: 0, seconds: 0)
            d.count += 1
            d.seconds += (t.resultTs ?? t.startedTs) - t.startedTs
            by[l] = d
        }
        return Array(by.values.sorted { ($0.count, $0.seconds) > ($1.count, $1.seconds) }.prefix(limit))
    }

    /// 턴 id → 그 턴 동안 뜬 실제 승인 프롬프트 수. 같은 세션에서 프롬프트 시각 직전의 턴에 붙인다.
    static func permissionsByTurn(turns: [ObsTurn], permissions: [ObsPermission]) -> [String: Int] {
        let bySession = Dictionary(grouping: turns, by: \.ccSessionId).mapValues { $0.sorted { $0.ts < $1.ts } }
        var out: [String: Int] = [:]
        for p in permissions {
            guard let t = bySession[p.ccSessionId]?.last(where: { $0.ts <= p.ts }) else { continue }
            out[t.id, default: 0] += 1
        }
        return out
    }

    static func repeatedReads(_ tools: [ObsTool], threshold: Int = 4) -> [Count] {
        counted(tools.filter { $0.name == "Read" }.compactMap(\.target)).filter { $0.count >= threshold }
    }

    static func failures(_ tools: [ObsTool], limit: Int = 10) -> [Failure] {
        var groups: [String: Failure] = [:]
        var order: [String] = []
        for t in tools where t.isError && !t.denied {
            let target = String((t.target ?? "").prefix(60)), err = t.errorHead ?? ""
            let k = "\(t.name)|\(target)|\(err)"
            if groups[k] == nil { order.append(k); groups[k] = Failure(tool: t.name, target: target, error: err, count: 0) }
            groups[k]!.count += 1
        }
        return Array(order.compactMap { groups[$0] }.sorted { $0.count > $1.count }.prefix(limit))
    }

    static func skillsAndMCP(_ tools: [ObsTool]) -> [Count] {
        counted(tools.compactMap { t -> String? in
            if t.name == "Skill", let s = t.target { return "skill:\(s)" }
            if t.name.hasPrefix("mcp__") { return "mcp:\(t.name.components(separatedBy: "__").dropFirst().first ?? "?")" }
            return nil
        }).sorted { ($0.count, $1.label) > ($1.count, $0.label) }
    }

    static func summary(_ tools: [ObsTool]) -> String {
        counted(tools.map(label)).map { "\($0.label)×\($0.count)" }.joined(separator: " · ")
    }

    /// 횟수 내림차순, 같으면 처음 나온 순서.
    private static func counted(_ labels: [String]) -> [Count] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for l in labels {
            if counts[l] == nil { order.append(l) }
            counts[l, default: 0] += 1
        }
        return order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map { Count(label: $0.element, count: counts[$0.element]!) }
    }
}
