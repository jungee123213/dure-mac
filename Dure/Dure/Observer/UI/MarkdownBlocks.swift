// Dure/Dure/Observer/UI/MarkdownBlocks.swift
import SwiftUI

/// 리포트 렌더. 마크다운 라이브러리를 들이지 않는다 — `ReportRenderer` 가 쓰는 모양만 그린다.
enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(Int, String), paragraph(String), bullet(Int, String), quote(String), code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var code: [String]?
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "---" { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet(raw.prefix { $0 == " " }.count / 2, String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(line))
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        return out
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, t):
                    Text(inline(t)).font(level <= 2 ? .title3.bold() : .headline).padding(.top, 6)
                case let .paragraph(t):
                    Text(inline(t))
                case let .bullet(indent, t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(inline(t)) }
                        .padding(.leading, CGFloat(indent) * 16)
                case let .quote(t):
                    Text(inline(t)).foregroundStyle(.secondary).padding(.leading, 10)
                case let .code(t):
                    Text(t).font(.system(.body, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
