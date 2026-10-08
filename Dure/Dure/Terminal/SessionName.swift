import Foundation

/// 이슈 #16 · D-31 — `claude --name`.
///
/// Claude Code 의 세션 간 메시지는 범위를 좁힐 수 없다. 조율자는 지시문의 규칙
/// ("이 접두사로 시작하는 세션에만 보낸다") 으로 같은 워크스페이스를 고른다. 그래서 **접두사가
/// 워크스페이스를 유일하게 가리켜야 한다** — 이름만 쓰면 같은 이름의 워크스페이스 둘이 섞인다.
/// 그래서 워크스페이스 UUID 앞 4자를 넣는다.
enum SessionName {

    /// `@` 멘션이 따옴표 없이 받는 글자(글자·숫자·`-`·`_`)만 남긴다. 공백은 `-`.
    static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isWhitespace || ch == "-" {
                if !out.isEmpty, out.last != "-" { out.append("-") }
            } else if ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "x" : out
    }

    static func shortID(_ workspaceID: String) -> String {
        String(workspaceID.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(4))
    }

    static func prefix(workspaceName: String, workspaceID: String) -> String {
        "dure-\(slug(workspaceName))-\(shortID(workspaceID))-"
    }

    static func repo(workspaceName: String, workspaceID: String, repoName: String) -> String {
        prefix(workspaceName: workspaceName, workspaceID: workspaceID) + slug(repoName)
    }

    static func orchestrator(workspaceName: String, workspaceID: String) -> String {
        prefix(workspaceName: workspaceName, workspaceID: workspaceID) + "조율자"
    }
}
