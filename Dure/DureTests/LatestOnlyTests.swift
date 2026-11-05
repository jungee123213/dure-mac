// Dure/DureTests/LatestOnlyTests.swift
import Foundation
import Testing
@testable import Dure

/// 이슈 #35 최종 리뷰 — 기간을 "전체" 에서 "오늘" 로 빨리 바꾸면, 늦게 끝난 "전체" 계산이 "오늘" 결과를 덮어썼다.
@MainActor
struct LatestOnlyTests {

    @Test func 늦게_끝난_이전_요청의_결과는_버린다() async {
        let latest = LatestOnly()
        var release: CheckedContinuation<Void, Never>?
        let slow = Task { @MainActor in
            await latest.run {
                await withCheckedContinuation { release = $0 }
                return "전체"
            }
        }
        while release == nil { await Task.yield() }          // 느린 요청이 시작될 때까지
        let fast = await latest.run { "오늘" }
        release?.resume()
        #expect(fast == "오늘")
        #expect(await slow.value == nil)
    }

    @Test func 겹치지_않으면_그대로_돌려준다() async {
        let latest = LatestOnly()
        #expect(await latest.run { 1 } == 1)
        #expect(await latest.run { 2 } == 2)
    }
}
