import CryptoKit
import Foundation

/// `codex app-server` JSON-RPC 코덱 — 보낼 메시지 만들기와 받은 메시지 해석. 순수 함수라 격리하지 않는다.
///
/// 모양은 codex-cli 0.167.0 실측(docs/spikes/2026-11-19-codex/f-stage1.md · schema-0.167.0/) 그대로다.
/// 메시지에 `"jsonrpc"` 필드가 없다. WebSocket 에서는 텍스트 프레임 하나, stdio 에서는 한 줄이 메시지 하나다.
nonisolated enum CodexAppServer {

    // MARK: - 보내는 메시지

    /// 처음 붙은 클라이언트 이름이 rollout 의 originator · userAgent 앞부분이 된다 — 그래서 `dure` 로 먼저 붙는다.
    static func initialize(id: Int) -> Data {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return encode(["id": id, "method": "initialize",
                       "params": ["clientInfo": ["name": "dure", "title": "Dure",
                                                 "version": (version?.isEmpty == false ? version! : "0")]]])
    }

    static func initialized() -> Data {
        encode(["method": "initialized"])
    }

    static func hooksList(id: Int, cwd: String) -> Data {
        encode(["id": id, "method": "hooks/list", "params": ["cwds": [cwd]]])
    }

    /// 첫 턴 전에 이름을 붙이면 "제목 만들기" 임시 스레드가 생기지 않는다(실측 판정 5).
    static func setThreadName(id: Int, threadID: String, name: String) -> Data {
        encode(["id": id, "method": "thread/name/set", "params": ["threadId": threadID, "name": name]])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: - 받는 메시지

    enum Incoming: Equatable {
        case response(id: Int, ok: Bool)
        case hooksListResult(id: Int, entries: [HookEntry])
        /// `ephemeral == true` 는 첫 턴 중에 따로 뜨는 "제목 만들기" 스레드다 — 전달 주소로 잡지 않는다.
        case threadStarted(threadID: String, cwd: String?, ephemeral: Bool)
        /// `status.type` — `idle` · `active` · `notLoaded` · `systemError`
        case threadStatus(threadID: String, status: String)
        case threadClosed(threadID: String)
        /// 모르는 알림 · 서버 요청 · 모양이 어긋난 메시지. 값은 `method`(없으면 빈 문자열).
        case other(String)
    }

    /// `hooks/list` 항목 하나. 스키마 `HookMetadata` 에서 옮긴다 — `eventName`(camelCase) → `event`(PascalCase),
    /// `trustStatus` → `trusted`, `timeoutSec` → `timeout`, `pluginId` → `pluginID`.
    /// `handlerType` 이 `command` 가 아닌 훅은 `command` 가 빈 문자열이다(옮길 수 없다 — 플러그인 판정에만 쓴다).
    struct HookEntry: Equatable {
        /// 스키마 `source` 값 — `user` · `project` · `plugin` · `sessionFlags` …
        let source: String
        let pluginID: String?
        let event: String
        let matcher: String?
        let command: String
        let timeout: Int
        /// `trustStatus` 가 `trusted` 이거나 `managed`(관리자가 강제 — 신뢰 창이 뜨지 않는다)
        let trusted: Bool
        /// 스키마 `sourcePath` — 훅이 정의된 파일(`~/.codex/hooks.json` · `~/.codex/config.toml` …).
        /// 기본값을 둬서 브리프의 init(앞 7개 필드)이 그대로 쓰인다.
        var sourcePath: String? = nil
        /// 스키마 `key` — `<sourcePath>:<snake 이벤트>:<그룹>:<핸들러>`. 신뢰 표의 키다.
        var key: String? = nil
        /// 스키마 `currentHash` — 내용만으로 계산한 해시(경로는 안 들어간다).
        var currentHash: String? = nil
    }

    /// JSON 이 아니거나 객체가 아니면 nil. `pendingHooksListID` 와 id 가 같은 성공 응답만 훅 목록으로 읽는다.
    static func parse(_ data: Data, pendingHooksListID: Int?) -> Incoming? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let o = object as? [String: Any] else { return nil }
        let method = o["method"] as? String

        if method == nil, let id = intValue(o["id"]) {
            if o["error"] != nil { return .response(id: id, ok: false) }
            guard let result = o["result"] else { return .other("") }
            if id == pendingHooksListID, let r = result as? [String: Any], let data = r["data"] as? [[String: Any]] {
                return .hooksListResult(id: id, entries: hookEntries(data))
            }
            return .response(id: id, ok: true)
        }
        guard let method else { return .other("") }
        // id 가 있으면 서버 → 클라이언트 요청이다(구독 없는 연결에는 안 온다). 알림으로 읽지 않는다.
        if o["id"] != nil { return .other(method) }

        let params = o["params"] as? [String: Any] ?? [:]
        switch method {
        case "thread/started":
            guard let t = params["thread"] as? [String: Any], let id = t["id"] as? String else { return .other(method) }
            return .threadStarted(threadID: id, cwd: t["cwd"] as? String, ephemeral: t["ephemeral"] as? Bool ?? false)
        case "thread/status/changed":
            guard let id = params["threadId"] as? String,
                  let type = (params["status"] as? [String: Any])?["type"] as? String else { return .other(method) }
            return .threadStatus(threadID: id, status: type)
        case "thread/closed":
            guard let id = params["threadId"] as? String else { return .other(method) }
            return .threadClosed(threadID: id)
        default:
            return .other(method)
        }
    }

    /// JSONSerialization 은 숫자를 NSNumber 로 준다. Bool 은 id 로 받지 않는다.
    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// `enabled: false` 인 훅은 돌지도 신뢰 창을 띄우지도 않으므로 뺀다. 필수 필드가 빠진 항목도 뺀다.
    private static func hookEntries(_ data: [[String: Any]]) -> [HookEntry] {
        data.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { h in
            guard let event = h["eventName"] as? String,
                  let source = h["source"] as? String,
                  let trust = h["trustStatus"] as? String,
                  h["enabled"] as? Bool ?? true else { return nil }
            let isCommand = h["handlerType"] as? String == "command"
            return HookEntry(source: source,
                             pluginID: h["pluginId"] as? String,
                             event: pascalEvent(event),
                             matcher: h["matcher"] as? String,
                             command: isCommand ? (h["command"] as? String ?? "") : "",
                             timeout: intValue(h["timeoutSec"]) ?? 0,
                             trusted: trust == "trusted" || trust == "managed",
                             sourcePath: h["sourcePath"] as? String,
                             key: h["key"] as? String,
                             currentHash: h["currentHash"] as? String)
        }
    }

    /// 스키마 `HookEventName` 은 camelCase(`sessionStart`), `CodexHooks.Group` 은 PascalCase(`SessionStart`).
    static func pascalEvent(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    // MARK: - 훅 목록 판정

    /// 신뢰 안 된 훅이 하나라도 있는 플러그인 — 페인 서버에서 끈다(안 끄면 TUI 에 "Hooks need review" 창).
    /// id 에 `.` 이 든 플러그인은 뺀다 — `-c plugins.<id>.enabled=false` 의 키가 점에서 갈라져 다른 키가 된다.
    /// 빼면 그 플러그인의 훅 검토 창이 뜰 수 있다(로그로 남긴다).
    static func pluginsToDisable(_ entries: [HookEntry]) -> [String] {
        let all = Set(entries.compactMap { $0.trusted ? nil : $0.pluginID }).sorted()
        let dotted = all.filter { $0.contains(".") }
        if !dotted.isEmpty {
            NSLog("[Dure] Codex: id 에 '.' 이 있어 -c 로 끌 수 없는 플러그인 — \(dotted.joined(separator: ", ")). 훅 검토 창이 뜰 수 있습니다")
        }
        return all.filter { !$0.contains(".") }
    }

    /// 사용자 `hooks.json` 의 신뢰된 command 훅 — 페인 home 은 hooks.json 을 만들지 않으므로 세션 플래그로 옮긴다. 원래 순서.
    /// `config.toml [hooks]` 는 옮기지 않는다 — CodexHome 이 config 사본에 이미 담아 가므로 옮기면 두 번 돈다
    /// (그 신뢰는 `configTrustToCarry` 가 옮긴다).
    static func userGroupsToCarry(_ entries: [HookEntry]) -> [CodexHooks.Group] {
        entries.filter {
            $0.source == "user" && $0.trusted && $0.pluginID == nil && !$0.command.isEmpty
                && ($0.sourcePath?.hasSuffix("/hooks.json") ?? false)
        }
            .map { CodexHooks.Group(event: $0.event, matcher: $0.matcher, command: $0.command, timeout: $0.timeout) }
    }

    /// 사용자 `config.toml [hooks]` 의 신뢰된 훅 — 페인 home 의 config 사본에서는 키 앞부분(파일 경로)이 바뀌어
    /// 사본에 딸려 간 `[hooks.state]` 와 맞지 않는다. 키 앞부분만 사본 경로로 바꾸고 해시는 그대로 둔다(내용만으로 계산).
    static func configTrustToCarry(_ entries: [HookEntry], paneConfigPath: String) -> [CodexHooks.TrustState] {
        entries.compactMap { e in
            guard e.source == "user", e.trusted, e.pluginID == nil,
                  let path = e.sourcePath, path.hasSuffix("/config.toml"),
                  let key = e.key, key.hasPrefix(path + ":"),
                  let hash = e.currentHash, !hash.isEmpty else { return nil }
            return CodexHooks.TrustState(key: paneConfigPath + key.dropFirst(path.count), hash: hash)
        }
    }
}

// MARK: - WebSocket 프레이밍 (RFC 6455)

/// 손으로 짠 WebSocket — `NWProtocolWebSocket` 이 `.unix` 끝점에서 안 되기 때문이다(실측 M6).
/// 클라이언트 → 서버 프레임은 마스킹, 서버 프레임은 마스킹하지 않는다(마스킹돼 와도 푼다).
nonisolated enum CodexWebSocketFrame {

    struct Frame: Equatable {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    enum Decoded: Equatable {
        case needMore
        case frame(Frame, consumed: Int)
        case invalid
    }

    enum Handshake: Equatable {
        case needMore
        /// 응답 헤더 끝(`\r\n\r\n`)까지의 바이트 수. 뒤는 첫 프레임이다.
        case upgraded(consumed: Int)
        case failed(String)
    }

    /// 서버가 알리는 한도(`x-codex-websocket-max-unfragmented-message-bytes: 16777216`)보다 넉넉히.
    static let maxPayload = 64 << 20

    static func encode(opcode: UInt8, payload: Data, mask: [UInt8]? = nil) -> Data {
        let m = mask ?? (0..<4).map { _ in UInt8.random(in: 0...255) }
        let n = payload.count
        var f = Data([0x80 | (opcode & 0x0f)])
        if n < 126 {
            f.append(0x80 | UInt8(n))
        } else if n < 65536 {
            f.append(0x80 | 126)
            f.append(contentsOf: [UInt8(n >> 8), UInt8(n & 0xff)])
        } else {
            f.append(0x80 | 127)
            f.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(n) >> (UInt64($0) * 8)) & 0xff) })
        }
        f.append(contentsOf: m)
        f.append(contentsOf: payload.enumerated().map { $1 ^ m[$0 % 4] })
        return f
    }

    static func decode(_ buffer: Data) -> Decoded {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return .needMore }
        let masked = b[1] & 0x80 != 0
        var length = UInt64(b[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return .needMore }
            length = UInt64(b[2]) << 8 | UInt64(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return .needMore }
            length = b[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            offset = 10
        }
        guard length <= UInt64(maxPayload) else { return .invalid }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= offset + 4 else { return .needMore }
            mask = Array(b[offset..<offset + 4])
            offset += 4
        }
        let n = Int(length)
        guard buffer.count >= offset + n else { return .needMore }
        let start = buffer.startIndex + offset
        var payload = Data(buffer[start..<start + n])
        if masked {
            payload = Data(payload.enumerated().map { $1 ^ mask[$0 % 4] })
        }
        return .frame(Frame(fin: b[0] & 0x80 != 0, opcode: b[0] & 0x0f, payload: payload), consumed: offset + n)
    }

    static func upgradeRequest(key: String) -> Data {
        Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
    }

    static func randomKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    static func acceptValue(forKey key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    static func parseHandshake(_ buffer: Data, key: String) -> Handshake {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .needMore }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first ?? ""
        let parts = status.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1] == "101" else { return .failed(status) }
        var accept: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-accept" {
                accept = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard accept == acceptValue(forKey: key) else { return .failed("sec-websocket-accept 불일치") }
        return .upgraded(consumed: end.upperBound - buffer.startIndex)
    }
}

/// 받은 바이트를 메시지로 — 조각(opcode 0)을 잇고 제어 프레임을 알린다. 잘못된 흐름을 만나면 멈춘다.
nonisolated struct CodexWebSocketReader {

    enum Event: Equatable {
        /// 텍스트 메시지 하나(= JSON-RPC 메시지 하나). 바이너리는 버린다.
        case message(Data)
        case ping(Data)
        case close
        case invalid
    }

    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8?
    private var stopped = false

    mutating func feed(_ data: Data) -> [Event] {
        guard !stopped else { return [] }
        buffer.append(data)
        var events: [Event] = []
        while !stopped {
            switch CodexWebSocketFrame.decode(buffer) {
            case .needMore:
                return events
            case .invalid:
                stopped = true
                events.append(.invalid)
            case .frame(let f, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                if let e = handle(f) {
                    events.append(e)
                    if e == .close || e == .invalid { stopped = true }
                }
            }
        }
        return events
    }

    private mutating func handle(_ f: CodexWebSocketFrame.Frame) -> Event? {
        switch f.opcode {
        case 0x8: return .close
        case 0x9: return .ping(f.payload)
        case 0xA: return nil   // pong
        case 0x1, 0x2:
            guard fragmentOpcode == nil else { return .invalid }
            if f.fin { return f.opcode == 0x1 ? .message(f.payload) : nil }
            fragmentOpcode = f.opcode
            fragments = f.payload
            return fragments.count > CodexWebSocketFrame.maxPayload ? .invalid : nil
        case 0x0:
            guard let op = fragmentOpcode else { return .invalid }
            fragments.append(f.payload)
            if fragments.count > CodexWebSocketFrame.maxPayload { return .invalid }
            guard f.fin else { return nil }
            fragmentOpcode = nil
            let whole = fragments
            fragments = Data()
            return op == 0x1 ? .message(whole) : nil
        default:
            return .invalid
        }
    }
}
