// Dure/Dure/Dashboard/LatestOnly.swift
import Foundation

/// 가장 최근 요청의 결과만 돌려준다. 이슈 #35 최종 리뷰 — `.task(id:)` 는 id 가 바뀌면 이전 태스크를 취소만 하는데,
/// 계산은 `Task.detached` 라 취소가 전파되지 않아 늦게 끝난 이전 계산(예: "전체")이 새 결과("오늘")를 덮어썼다.
@MainActor
final class LatestOnly {
    private var current = 0

    /// 그 사이 새 요청이 시작됐으면 `nil`(버림).
    func run<T>(_ work: () async -> T) async -> T? {
        current += 1
        let mine = current
        let result = await work()
        return mine == current ? result : nil
    }
}
