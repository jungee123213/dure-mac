import Foundation
import Testing
@testable import Dure

/// Review Focus 5 — 유닉스 소켓 경로는 104바이트 한도다 (실측: 122바이트에서 `AF_UNIX path too long`).
struct MCPSocketPathTests {

    @Test func 세션_앞_8자로_짧게_만든다() {
        let root = URL(fileURLWithPath: "/Users/me/.dure")
        #expect(MCPSocketPath.path(forSession: "ABCDEF12-3456-7890-ABCD-EF1234567890", root: root)
                == "/Users/me/.dure/mcp/abcdef12.sock")
    }

    @Test func 한도_안이면_통과한다() throws {
        try MCPSocketPath.check("/tmp/x.sock")
        try MCPSocketPath.check(String(repeating: "a", count: 103))
    }

    @Test func 한도를_넘으면_거부한다() {
        let long = "/" + String(repeating: "한", count: 40) + ".sock"   // 한글 1자 = 3바이트
        #expect(throws: MCPSocketPath.Problem.self) { try MCPSocketPath.check(long) }
    }

    @Test func nc_는_절대경로다() {
        #expect(MCPSocketPath.ncPath == "/usr/bin/nc")
        #expect(MCPSocketPath.ncExists())
    }
}
