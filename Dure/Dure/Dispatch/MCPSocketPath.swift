import Foundation

/// 단계 4 — 페인마다 하나인 MCP 소켓의 경로. **경로가 곧 신원**이라 세션 id 에서 만든다.
///
/// `sockaddr_un.sun_path` 는 macOS 에서 104바이트이고 NUL 이 들어가므로 103바이트까지다.
/// 스크래치 디렉토리(122바이트)에서 서버가 못 뜬 실측이 있다. `~/.dure/mcp/<8자>.sock` 은 70바이트 안팎이지만
/// 홈 경로가 긴 사용자가 있을 수 있어 검사한다.
enum MCPSocketPath {

    static let maxBytes = 103
    static let ncPath = "/usr/bin/nc"

    enum Problem: Error, Equatable {
        case tooLong(bytes: Int)
        case ncMissing

        var message: String {
            switch self {
            case .tooLong(let n): "MCP 소켓 경로가 너무 깁니다 (\(n)바이트, 한도 \(maxBytes)). 홈 경로가 긴 계정입니다."
            case .ncMissing: "\(ncPath) 가 없습니다. MCP 연결에 필요합니다."
            }
        }
    }

    static func dir(root: URL = HookBridge.home) -> URL {
        root.appendingPathComponent("mcp", isDirectory: true)
    }

    /// 세션 UUID 앞 8자(소문자). 충돌은 `Dispatcher` 가 기존 소켓과 비교해 전체 UUID 로 피한다.
    static func path(forSession dureSession: String, root: URL = HookBridge.home) -> String {
        let short = String(dureSession.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        return dir(root: root).appendingPathComponent("\(short).sock").path
    }

    static func check(_ path: String) throws {
        let n = path.utf8.count
        if n > maxBytes { throw Problem.tooLong(bytes: n) }
    }

    static func ncExists() -> Bool {
        FileManager.default.isExecutableFile(atPath: ncPath)
    }
}
