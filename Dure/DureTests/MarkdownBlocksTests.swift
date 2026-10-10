// Dure/DureTests/MarkdownBlocksTests.swift
import Testing
@testable import Dure

/// SwiftUI `Text` 는 마크다운의 줄 안 문법만 그린다 — 머리글 · 목록 · 인용 · 코드는 줄 단위로 나눈다.
struct MarkdownBlocksTests {
    @Test func 머리글_목록_인용_문단() {
        #expect(MarkdownBlocks.parse("## 요약\n좋았다 **굵게**\n\n- 하나\n  - 둘\n> 인용\n### 두레") ==
                [.heading(2, "요약"), .paragraph("좋았다 **굵게**"), .bullet(0, "하나"), .bullet(1, "둘"), .quote("인용"), .heading(3, "두레")])
    }
    @Test func 코드_블록() {
        #expect(MarkdownBlocks.parse("```\nBash(git -C /r status *)\n```") == [.code("Bash(git -C /r status *)")])
    }
}
