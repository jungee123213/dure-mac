// Dure/Dure/Observer/ReflogBranch.swift
import Foundation

/// reflog → "그 시각에 어느 브랜치였나". **순수 함수.** 이슈 #32.
///
/// 실측: 브랜치 이름에 `#` 이 있으면(`feat/#30/x`) 트랜스크립트 `gitBranch` 가 `"HEAD"` 로 남는다.
/// HEAD reflog 의 전환 기록은 시각과 함께 남아 있어 그 시점의 브랜치를 되살릴 수 있다.
nonisolated enum ReflogBranch {

    struct Switch: Equatable, Sendable {
        var ts: Int
        /// rebase 종료 항목은 출발지를 모른다.
        var from: String?
        var to: String
    }

    struct Log: Equatable, Sendable {
        /// 전환 항목만, 시각 오름차순.
        var switches: [Switch]
        /// 남아 있는 가장 오래된 항목(전환이 아니어도)의 시각. reflog 는 만료로 잘린다 — 이보다 이전은 알 수 없다.
        var oldest: Int?
    }

    /// `git reflog --date=unix --format=%gd%x09%gs` 출력(최신이 위) → 전환 항목만, 시각 오름차순.
    /// 브랜치를 바꾸는 것은 `checkout: moving from A to B` 와 `… (finish): returning to refs/heads/X` 둘뿐이다.
    /// rebase start · pick 의 일시 detached 는 전환으로 보지 않는다.
    static func parse(_ text: String) -> Log {
        var out: [Switch] = []
        var oldest: Int?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let ts = timestamp(parts[0]) else { continue }
            oldest = min(oldest ?? ts, ts)
            let subject = String(parts[1])
            if subject.hasPrefix("checkout: moving from ") {
                // git 브랜치 이름에는 공백이 들어갈 수 없다.
                let words = subject.dropFirst("checkout: moving from ".count).split(separator: " ")
                guard words.count == 3, words[1] == "to" else { continue }
                out.append(Switch(ts: ts, from: String(words[0]), to: String(words[2])))
            } else if let r = subject.range(of: "(finish): returning to refs/heads/") {
                let to = String(subject[r.upperBound...])
                if !to.isEmpty { out.append(Switch(ts: ts, from: nil, to: to)) }
            }
        }
        // 입력은 최신이 위 — 뒤집으면 같은 초 안에서도 실제 일어난 순서가 된다. 정렬은 안정 정렬이어야 한다.
        let switches = Array(out.reversed()).enumerated()
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
            .map(\.element)
        return Log(switches: switches, oldest: oldest)
    }

    /// 시각 `ts` 의 브랜치. 같은 초면 전환이 먼저 일어난 것으로 본다(`<=`).
    /// 첫 전환 이전이면 그 출발지(rebase 종료 항목이면 그 브랜치) — 단 남은 기록 범위 안일 때만.
    /// 기록보다 이전이거나 알 수 없으면 `nil`, 커밋 해시로 체크아웃한 상태면 `"HEAD"`.
    static func branch(at ts: Int, in log: Log) -> String? {
        guard let oldest = log.oldest, ts >= oldest else { return nil }
        let name: String?
        if let last = log.switches.last(where: { $0.ts <= ts }) {
            name = last.to
        } else if let first = log.switches.first {
            name = first.from ?? first.to
        } else {
            name = nil
        }
        guard let name else { return nil }
        return isHash(name) ? "HEAD" : name
    }

    private static func timestamp(_ selector: Substring) -> Int? {
        guard selector.hasPrefix("HEAD@{"), selector.hasSuffix("}") else { return nil }
        return Int(selector.dropFirst("HEAD@{".count).dropLast())
    }

    private static func isHash(_ s: String) -> Bool {
        (7...40).contains(s.count) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
