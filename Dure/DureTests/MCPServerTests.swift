import Foundation
import Testing
@testable import Dure

/// 단계 4 — 진짜 소켓, 진짜 `nc -U`. 문자열 테스트로는 "줄이 끊겨 오는 것" 과 "동시 연결" 을 못 본다.
struct MCPServerTests {

    /// 유닉스 소켓 104바이트 한도 때문에 임시 디렉토리가 아니라 `/tmp` 아래다.
    static func shortDir() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/dure-t-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return d
    }

    /// 떠 있는 `nc -U` 하나. 연결을 열어 둔 채 줄을 보내고 받을 수 있어야 "동시 연결" 을 본다.
    /// macOS `nc` 는 stdin EOF 면 서버 응답을 기다리지 않고 끝난다. 그래서 고정 sleep 뒤 stdin 을 닫으면
    /// 부하가 걸린 전체 테스트에서 늦은 응답(비동기 테스트)을 놓친다 — 실측. stdin 을 열어 둔 채
    /// 기대한 줄 수가 올 때까지(최대 2초) stdout 을 읽고, 그다음에 닫는다.
    final class NC {
        private let p = Process()
        private let inPipe = Pipe(), outPipe = Pipe()
        private var data = Data()

        init(_ path: String) throws {
            p.executableURL = URL(fileURLWithPath: MCPSocketPath.ncPath)
            p.arguments = ["-U", path]
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = Pipe()
            try p.run()
        }

        func send(_ lines: [String]) {
            inPipe.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }

        /// 지금까지 받은 줄이 `expect` 개가 될 때까지 기다린다(최대 2초).
        func wait(for expect: Int) {
            let fd = outPipe.fileHandleForReading.fileDescriptor
            let deadline = Date().addingTimeInterval(2)
            while data.filter({ $0 == 0x0A }).count < expect, Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 50) > 0 else { continue }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }   // nc 가 먼저 끝났다
                data.append(contentsOf: buf[0..<n])
            }
        }

        /// stdin 을 닫고 남은 출력까지 받아 줄로 돌려준다. 기대보다 더 온 줄도 비교에 드러난다.
        func finish() throws -> [String] {
            try inPipe.fileHandleForWriting.close()
            data.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    static func nc(_ path: String, lines: [String], expect: Int) throws -> [String] {
        let c = try NC(path)
        c.send(lines)
        c.wait(for: expect)
        return try c.finish()
    }

    /// `nc` 와 달리 받은 것을 **읽지 않는** 클라이언트. 서버 쪽 write 가 막혀 있는 동안 끊어야 해서다.
    static func rawConnect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: cap) { strncpy($0, src, cap - 1) }
            }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0 ? fd : -1
    }

    @Test func 줄마다_응답하고_알림은_건너뛴다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        let server = MCPServer(path: path) { line, reply in
            reply(line.contains("\"id\"") ? "{\"echo\":\(line.count)}" : nil)
        }
        try server.start()
        defer { server.stop() }
        let out = try Self.nc(path, lines: [#"{"id":1,"method":"x"}"#, #"{"method":"n"}"#, #"{"id":2,"method":"y"}"#], expect: 2)
        #expect(out == ["{\"echo\":21}", "{\"echo\":21}"])
    }

    @Test func 소켓_파일은_소유자만_접근한다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("b.sock").path
        let server = MCPServer(path: path) { _, reply in reply(nil) }
        try server.start()
        let perm = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perm == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// `/mcp` 재연결처럼 연결이 둘 와도 각자 답한다.
    @Test func 연결_둘이_섞이지_않는다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        let server = MCPServer(path: path) { line, reply in reply("re:" + line) }
        try server.start()
        defer { server.stop() }
        let a = try Self.nc(path, lines: ["A1", "A2"], expect: 2)
        let b = try Self.nc(path, lines: ["B1"], expect: 1)
        #expect(a == ["re:A1", "re:A2"] && b == ["re:B1"])
    }

    /// 응답이 늦게 와도(메인액터 hop) 그 연결로 간다.
    @Test func 비동기_응답도_같은_연결로_돌아온다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("d.sock").path
        let server = MCPServer(path: path) { line, reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { reply("late:" + line) }
        }
        try server.start()
        defer { server.stop() }
        #expect(try Self.nc(path, lines: ["q"], expect: 1) == ["late:q"])
    }

    @Test func 이미_있는_소켓_파일은_치우고_뜬다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("e.sock").path
        try Data().write(to: URL(fileURLWithPath: path))   // 지난번 앱이 남긴 잔해
        let server = MCPServer(path: path) { _, reply in reply("ok") }
        try server.start()
        defer { server.stop() }
        #expect(try Self.nc(path, lines: ["x"], expect: 1) == ["ok"])
    }

    /// 두 연결이 **동시에** 열려 있고 줄이 엇갈려 와도 각자 자기 응답만 받는다.
    @Test func 동시에_열린_연결_둘이_섞이지_않는다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("f.sock").path
        let server = MCPServer(path: path) { line, reply in
            // 응답을 조금 늦춰 두 연결의 응답이 실제로 엇갈리게 한다.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { reply("re:" + line) }
        }
        try server.start()
        defer { server.stop() }
        let a = try NC(path), b = try NC(path)
        a.send(["A1"]); b.send(["B1"]); a.send(["A2"]); b.send(["B2"])
        a.wait(for: 2); b.wait(for: 2)
        let ra = try a.finish(), rb = try b.finish()
        // 응답이 global 큐의 asyncAfter 로 오므로 한 연결 안의 순서는 보장되지 않는다.
        // 보려는 것은 "연결끼리 섞이지 않음" 이라 정렬해 비교한다.
        #expect(ra.sorted() == ["re:A1", "re:A2"])
        #expect(rb.sorted() == ["re:B1", "re:B2"])
    }

    /// 상대가 사라진 소켓에 쓰면 SIGPIPE 가 **앱 전체**를 죽인다. 늦은 응답 · 쓰는 도중 끊김 둘 다 살아남아야 한다.
    /// 큰 응답은 소켓 버퍼를 채워 write 가 막힌 채로 상대가 끊기게 만든다 — EOF 를 먼저 보고 응답을 버리는
    /// 경로로 새지 않고 write 가 반드시 끊긴 소켓을 만나게 하는 결정적 방법이다.
    @Test func 끊긴_연결에_응답해도_앱이_죽지_않는다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("g.sock").path
        let server = MCPServer(path: path) { line, reply in
            switch line {
            case "late": DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply("late") }
            case "big": reply(String(repeating: "x", count: 1 << 20))
            default: reply("pong")
            }
        }
        try server.start()
        defer { server.stop() }

        // 1) 보내자마자 끊고, 응답은 0.3초 뒤에 온다.
        _ = try Self.nc(path, lines: ["late"], expect: 0)
        Thread.sleep(forTimeInterval: 0.6)

        // 2) 1MB 응답을 읽지 않고 버티다 끊는다. 서버 write 는 그동안 막혀 있다가 EPIPE 를 만난다.
        let fd = Self.rawConnect(path)
        #expect(fd >= 0)
        _ = "big\n".withCString { write(fd, $0, 4) }
        Thread.sleep(forTimeInterval: 0.3)
        close(fd)
        Thread.sleep(forTimeInterval: 0.3)

        // 여기까지 왔으면 프로세스는 살아 있다. 서버도 새 연결에 답해야 한다.
        #expect(try Self.nc(path, lines: ["ping"], expect: 1) == ["pong"])
    }

    /// I-5 — 붙어서 읽지 않는 연결 하나가 직렬 소켓 큐를 영원히 막으면 다른 연결(다른 페인)도 답을 못 받는다.
    /// 쓰기 제한(2초)이 지나면 그 연결을 닫고 다음 연결에 답한다.
    @Test func 읽지_않는_연결이_서버를_멈추지_않는다() throws {
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("j.sock").path
        let server = MCPServer(path: path) { line, reply in
            reply(line == "big" ? String(repeating: "x", count: 1 << 20) : "pong")
        }
        try server.start()
        defer { server.stop() }
        let fd = Self.rawConnect(path)
        #expect(fd >= 0)
        defer { close(fd) }
        _ = "big\n".withCString { write(fd, $0, 4) }
        Thread.sleep(forTimeInterval: 2.5)   // 끊지 않고 읽지도 않는다
        #expect(try Self.nc(path, lines: ["ping"], expect: 1) == ["pong"])
    }

    /// 응답 콜백 안(= 소켓 큐 위)에서 `stop()` 을 불러도, 마지막 참조가 큐 위에서 놓여 `deinit` 이 돌아도
    /// `queue.sync` 재진입으로 죽지 않는다.
    @Test func 소켓_큐_위에서_멈추고_해제해도_죽지_않는다() throws {
        final class Box: @unchecked Sendable { var server: MCPServer? }
        let dir = try Self.shortDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        func waitGone(_ path: String) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while FileManager.default.fileExists(atPath: path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            return !FileManager.default.fileExists(atPath: path)
        }

        // stop() 을 큐 위에서.
        let stopPath = dir.appendingPathComponent("h.sock").path
        let stopBox = Box()
        let s1 = MCPServer(path: stopPath) { _, reply in stopBox.server?.stop(); reply(nil) }
        stopBox.server = s1
        try s1.start()
        _ = try Self.nc(stopPath, lines: ["stop"], expect: 0)
        #expect(waitGone(stopPath))
        s1.stop()   // 두 번 불러도 괜찮다.
        stopBox.server = nil

        // 마지막 참조를 큐 위에서 놓는다 → deinit 이 큐 위에서 돈다.
        let dropPath = dir.appendingPathComponent("i.sock").path
        let dropBox = Box()
        dropBox.server = MCPServer(path: dropPath) { _, reply in dropBox.server = nil; reply(nil) }
        try dropBox.server?.start()
        _ = try Self.nc(dropPath, lines: ["drop"], expect: 0)
        #expect(waitGone(dropPath))
    }
}
