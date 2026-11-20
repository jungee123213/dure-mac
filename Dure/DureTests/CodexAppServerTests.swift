import Foundation
import Testing
@testable import Dure

/// 고정 예제는 docs/spikes/2026-11-19-codex/f-stage1.md 와 schema-0.167.0/ 의 실물 모양에서 만든다(codex-cli 0.167.0).
struct CodexAppServerTests {

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func parse(_ json: String, pending: Int? = nil) -> CodexAppServer.Incoming? {
        CodexAppServer.parse(Data(json.utf8), pendingHooksListID: pending)
    }

    // MARK: - 보내는 메시지

    @Test func initialize_는_dure_로_자기를_밝힌다() {
        let o = object(CodexAppServer.initialize(id: 1))
        #expect(o["id"] as? Int == 1)
        #expect(o["method"] as? String == "initialize")
        #expect(o["jsonrpc"] == nil)
        let info = (o["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "dure")
        #expect((info?["version"] as? String)?.isEmpty == false)   // 스키마 필수
    }

    @Test func initialized_는_params_없는_알림이다() {
        let o = object(CodexAppServer.initialized())
        #expect(o["method"] as? String == "initialized")
        #expect(o["id"] == nil)
        #expect(o["params"] == nil)
    }

    @Test func hooks_list_요청은_cwd_하나를_묻는다() {
        let o = object(CodexAppServer.hooksList(id: 2, cwd: "/Users/x/repo a"))
        #expect(o["id"] as? Int == 2)
        #expect(o["method"] as? String == "hooks/list")
        #expect((o["params"] as? [String: Any])?["cwds"] as? [String] == ["/Users/x/repo a"])
    }

    @Test func thread_name_set_요청() {
        let o = object(CodexAppServer.setThreadName(id: 7, threadID: "01a1f3f0-88f8", name: "두레 · 백엔드"))
        #expect(o["method"] as? String == "thread/name/set")
        let p = o["params"] as? [String: Any]
        #expect(p?["threadId"] as? String == "01a1f3f0-88f8")
        #expect(p?["name"] as? String == "두레 · 백엔드")
    }

    // MARK: - 받는 메시지

    private let threadStarted = #"""
    {"method":"thread/started","params":{"thread":{"id":"01a1f3ef-b58c-7351-aa65-f20e07956644","sessionId":"01a1f3ef-b58c-7351-aa65-f20e07956644","environments":[{"environmentId":"local","cwd":"/Users/x/work/repo","runtimeWorkspaceRoots":["/Users/x/work/repo"]}],"ephemeral":false,"threadSource":"user","path":"/Users/x/.dure/codex-home/repo-1/sessions/2026/11/19/rollout-2026-11-19T10-00-00-01a1f3ef.jsonl","cwd":"/Users/x/work/repo","cliVersion":"0.167.0","originator":"dure","source":"vscode","model":"gpt-5.6","modelProvider":"openai","reasoningEffort":"medium","status":{"type":"idle"},"name":null,"gitInfo":{"branch":"HEAD","originUrl":null,"sha":"a2dc0e1"},"createdAt":1795093930,"updatedAt":1795093930,"recencyAt":1795093930,"preview":"","projectId":null,"turns":[]}}}
    """#

    @Test func thread_started_알림에서_스레드_id_와_cwd_를_꺼낸다() {
        #expect(parse(threadStarted) == .threadStarted(threadID: "01a1f3ef-b58c-7351-aa65-f20e07956644",
                                                       cwd: "/Users/x/work/repo", ephemeral: false))
    }

    @Test func 제목_만들기_임시_스레드는_ephemeral_로_표시된다() {
        let json = #"""
        {"method":"thread/started","params":{"thread":{"id":"01a1f3ef-c215-7000-8000-000000000001","sessionId":"01a1f3ef-c215-7000-8000-000000000001","environments":[],"ephemeral":true,"threadSource":"thread_title","path":null,"cwd":"/Users/x/work/repo","cliVersion":"0.167.0","originator":"dure","source":"vscode","model":"gpt-5.6-luna","modelProvider":"openai","status":{"type":"idle"},"name":null,"gitInfo":null,"createdAt":1795093931,"updatedAt":1795093931,"preview":"","projectId":null,"turns":[]}}}
        """#
        #expect(parse(json) == .threadStarted(threadID: "01a1f3ef-c215-7000-8000-000000000001",
                                              cwd: "/Users/x/work/repo", ephemeral: true))
    }

    @Test func thread_status_changed_를_해석한다() {
        let active = #"{"method":"thread/status/changed","params":{"threadId":"01a1f3ef-b58c","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1795093936064}"#
        #expect(parse(active) == .threadStatus(threadID: "01a1f3ef-b58c", status: "active"))
        let notLoaded = #"{"method":"thread/status/changed","params":{"threadId":"01a1f3ef-b58c","status":{"type":"notLoaded"}}}"#
        #expect(parse(notLoaded) == .threadStatus(threadID: "01a1f3ef-b58c", status: "notLoaded"))
    }

    @Test func thread_closed_를_해석한다() {
        #expect(parse(#"{"method":"thread/closed","params":{"threadId":"01a1f3ef-b58c"}}"#)
                == .threadClosed(threadID: "01a1f3ef-b58c"))
    }

    @Test func 응답의_성공과_실패() {
        let ok = #"{"id":1,"result":{"userAgent":"dure/0.167.0 (Mac OS 26.6.2; arm64) iTerm.app/3.7.7 (dure; 0.1)","codexHome":"/Users/x/.dure/codex-home/repo-1","platformFamily":"unix","platformOs":"macos"}}"#
        #expect(parse(ok) == .response(id: 1, ok: true))
        let err = #"{"id":3,"error":{"code":-32600,"message":"invalid paginated history lineage"}}"#
        #expect(parse(err) == .response(id: 3, ok: false))
        #expect(parse(#"{"id":4,"result":{}}"#) == .response(id: 4, ok: true))   // thread/name/set
    }

    @Test func 모르는_메시지는_other_다() {
        #expect(parse(#"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}"#) == .other("account/updated"))
        #expect(parse(#"{"method":"thread/name/updated","params":{"threadId":"a","threadName":"x"}}"#) == .other("thread/name/updated"))
        // 필수 필드가 빠진 알림도 other — 죽지 않는다
        #expect(parse(#"{"method":"thread/started","params":{}}"#) == .other("thread/started"))
        #expect(parse(#"{"foo":1}"#) == .other(""))
    }

    @Test func 깨진_JSON_은_nil_이다() {
        #expect(parse("{\"id\":1,") == nil)
        #expect(parse("") == nil)
        #expect(parse("[1,2]") == nil)
        #expect(parse("Restored session: zshrc noise") == nil)
    }

    // MARK: - hooks/list

    /// 진짜 home stdio hooks/list 의 모양(M1): 사용자 hooks.json 훅 2개 trusted, 플러그인 훅 2개 modified.
    /// 사용자 훅 두 개의 command · currentHash 는 실물 그대로다(CodexHooksTests 와 같은 값).
    private let hooksListResult = #"""
    {"id":2,"result":{"data":[{"cwd":"/Users/x/work/repo","hooks":[
    {"key":"/Users/x/.codex/hooks.json:session_start:0:0","eventName":"sessionStart","handlerType":"command","command":"node \"/Users/qhrtj07/.claude/scripts/gptaku-update-check.cjs\"","async":false,"matcher":"*","timeoutSec":5,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"environmentId":null,"displayOrder":0,"enabled":true,"isManaged":false,"currentHash":"sha256:5064ac3e2883b8f01b2d389632f4d2c955bcdc915562897ffb99927e8b208ee0","trustStatus":"trusted"},
    {"key":"/Users/x/.codex/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"/Users/qhrtj07/.claude/skills/gstack/hosts/claude/hooks/timeline-stop-hook","async":false,"matcher":null,"timeoutSec":5,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"environmentId":null,"displayOrder":1,"enabled":true,"isManaged":false,"currentHash":"sha256:43864f118fe4d0aa73736ef8982048b5a26c0d90ac35af5458ad8ffcedfbca7b","trustStatus":"trusted"},
    {"key":"/Users/x/.codex/hooks.json:post_tool_use:0:0","eventName":"postToolUse","handlerType":"command","command":"/Users/x/bin/new-hook","async":false,"matcher":"Bash","timeoutSec":10,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"environmentId":null,"displayOrder":2,"enabled":true,"isManaged":false,"currentHash":"sha256:00","trustStatus":"untrusted"},
    {"key":"understand-anything@understand-anything:hooks/hooks.json:post_tool_use:0:0","eventName":"postToolUse","handlerType":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/post.js\"","async":false,"matcher":"Edit|Write","timeoutSec":30,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/plugins/cache/understand-anything/hooks/hooks.json","source":"plugin","pluginId":"understand-anything@understand-anything","environmentId":null,"displayOrder":3,"enabled":true,"isManaged":false,"currentHash":"sha256:aa/sha256:bb","trustStatus":"modified"},
    {"key":"understand-anything@understand-anything:hooks/hooks.json:session_start:0:0","eventName":"sessionStart","handlerType":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/start.js\"","async":false,"matcher":null,"timeoutSec":30,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/plugins/cache/understand-anything/hooks/hooks.json","source":"plugin","pluginId":"understand-anything@understand-anything","environmentId":null,"displayOrder":4,"enabled":true,"isManaged":false,"currentHash":"sha256:cc/sha256:dd","trustStatus":"modified"},
    {"key":"good@market:hooks/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"good-stop","async":false,"matcher":null,"timeoutSec":5,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/plugins/cache/good/hooks/hooks.json","source":"plugin","pluginId":"good@market","environmentId":null,"displayOrder":5,"enabled":true,"isManaged":false,"currentHash":"sha256:ee/sha256:ff","trustStatus":"trusted"},
    {"key":"bad@market:hooks/hooks.json:stop:0:0","eventName":"stop","handlerType":"mcpTool","server":"s","tool":"t","matcher":null,"timeoutSec":5,"statusMessage":null,"additionalContextLimit":null,"sourcePath":"/Users/x/.codex/plugins/cache/bad/hooks/hooks.json","source":"plugin","pluginId":"bad@market","environmentId":null,"displayOrder":6,"enabled":true,"isManaged":false,"currentHash":"sha256:11/sha256:22","trustStatus":"untrusted"}
    ],"warnings":[],"errors":[]}]}}
    """#

    private var entries: [CodexAppServer.HookEntry] {
        guard case .hooksListResult(_, let e)? = parse(hooksListResult, pending: 2) else { return [] }
        return e
    }

    @Test func hooks_list_응답은_기다리던_id_일_때만_결과로_읽는다() {
        guard case .hooksListResult(let id, let e)? = parse(hooksListResult, pending: 2) else {
            Issue.record("hooksListResult 가 아니다"); return
        }
        #expect(id == 2)
        #expect(e.count == 7)
        #expect(e[0] == CodexAppServer.HookEntry(source: "user", pluginID: nil, event: "SessionStart", matcher: "*",
            command: #"node "/Users/qhrtj07/.claude/scripts/gptaku-update-check.cjs""#, timeout: 5, trusted: true,
            sourcePath: "/Users/x/.codex/hooks.json"))
        #expect(e[3].sourcePath == "/Users/x/.codex/plugins/cache/understand-anything/hooks/hooks.json")
        #expect(e[1].event == "Stop")
        #expect(e[2].event == "PostToolUse")
        #expect(e[2].trusted == false)
        #expect(e[3].pluginID == "understand-anything@understand-anything")
        #expect(e[3].trusted == false)   // modified
        #expect(parse(hooksListResult, pending: nil) == .response(id: 2, ok: true))
        #expect(parse(hooksListResult, pending: 9) == .response(id: 2, ok: true))
    }

    @Test func 이벤트_이름은_PascalCase_로_옮긴다() {
        #expect(CodexAppServer.pascalEvent("sessionStart") == "SessionStart")
        #expect(CodexAppServer.pascalEvent("userPromptSubmit") == "UserPromptSubmit")
        #expect(CodexAppServer.pascalEvent("stop") == "Stop")
        #expect(CodexAppServer.pascalEvent("") == "")
    }

    @Test func hooks_list_결과에서_신뢰_안_된_플러그인만_끈다() {
        #expect(CodexAppServer.pluginsToDisable(entries) == ["bad@market", "understand-anything@understand-anything"])
    }

    @Test func 신뢰된_사용자_훅만_옮긴다() {
        #expect(CodexAppServer.userGroupsToCarry(entries) == [
            CodexHooks.Group(event: "SessionStart", matcher: "*",
                             command: #"node "/Users/qhrtj07/.claude/scripts/gptaku-update-check.cjs""#, timeout: 5),
            CodexHooks.Group(event: "Stop", matcher: nil,
                             command: "/Users/qhrtj07/.claude/skills/gstack/hosts/claude/hooks/timeline-stop-hook", timeout: 5),
        ])
        // 옮긴 훅의 신뢰 해시가 사용자 home 의 currentHash 와 같다(같은 훅이 세션 플래그로 신뢰된다)
        let carried = CodexAppServer.userGroupsToCarry(entries)
        #expect(CodexHooks.trustHash(carried[0]) == "sha256:5064ac3e2883b8f01b2d389632f4d2c955bcdc915562897ffb99927e8b208ee0")
        #expect(CodexHooks.trustHash(carried[1]) == "sha256:43864f118fe4d0aa73736ef8982048b5a26c0d90ac35af5458ad8ffcedfbca7b")
    }

    @Test func 꺼진_훅과_세션_플래그_훅은_옮기지_않는다() {
        let json = #"""
        {"id":5,"result":{"data":[{"cwd":"/r","hooks":[
        {"key":"/Users/x/.codex/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"off","async":false,"matcher":null,"timeoutSec":5,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"displayOrder":0,"enabled":false,"isManaged":false,"currentHash":"sha256:0","trustStatus":"trusted"},
        {"key":"/<session-flags>/config.toml:stop:0:0","eventName":"stop","handlerType":"command","command":"flag","async":false,"matcher":null,"timeoutSec":5,"sourcePath":"/<session-flags>/config.toml","source":"sessionFlags","pluginId":null,"displayOrder":1,"enabled":true,"isManaged":false,"currentHash":"sha256:1","trustStatus":"trusted"},
        {"key":"/Users/x/.codex/hooks.json:stop:1:0","eventName":"stop","handlerType":"prompt","matcher":null,"timeoutSec":5,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"displayOrder":2,"enabled":true,"isManaged":false,"currentHash":"sha256:2","trustStatus":"trusted"}
        ],"warnings":[],"errors":[]}]}}
        """#
        guard case .hooksListResult(_, let e)? = parse(json, pending: 5) else { Issue.record("결과 아님"); return }
        #expect(e.count == 2)   // 꺼진 훅은 목록에서 뺀다
        #expect(CodexAppServer.userGroupsToCarry(e).isEmpty)
    }

    @Test func config_toml_의_사용자_훅은_옮기지_않고_hooks_json_만_옮긴다() {
        // config.toml [hooks] 는 CodexHome 이 config 사본에 담아 간다 — 옮기면 두 번 돈다.
        let json = #"""
        {"id":6,"result":{"data":[{"cwd":"/r","hooks":[
        {"key":"/Users/x/.codex/config.toml:session_start:0:0","eventName":"sessionStart","handlerType":"command","command":"from-config","async":false,"matcher":"*","timeoutSec":5,"sourcePath":"/Users/x/.codex/config.toml","source":"user","pluginId":null,"displayOrder":0,"enabled":true,"isManaged":false,"currentHash":"sha256:0","trustStatus":"trusted"},
        {"key":"/Users/x/.codex/hooks.json:session_start:0:0","eventName":"sessionStart","handlerType":"command","command":"from-hooks-json","async":false,"matcher":"*","timeoutSec":5,"sourcePath":"/Users/x/.codex/hooks.json","source":"user","pluginId":null,"displayOrder":1,"enabled":true,"isManaged":false,"currentHash":"sha256:1","trustStatus":"trusted"},
        {"key":"/r/.codex/hooks.json:stop:0:0","eventName":"stop","handlerType":"command","command":"from-project","async":false,"matcher":null,"timeoutSec":5,"sourcePath":"/r/.codex/hooks.json","source":"project","pluginId":null,"displayOrder":2,"enabled":true,"isManaged":false,"currentHash":"sha256:2","trustStatus":"trusted"}
        ],"warnings":[],"errors":[]}]}}
        """#
        guard case .hooksListResult(_, let e)? = parse(json, pending: 6) else { Issue.record("결과 아님"); return }
        #expect(e.count == 3)
        #expect(e[0].sourcePath == "/Users/x/.codex/config.toml")
        #expect(CodexAppServer.userGroupsToCarry(e) == [
            CodexHooks.Group(event: "SessionStart", matcher: "*", command: "from-hooks-json", timeout: 5),
        ])
        // sourcePath 를 모르는 항목(브리프 init 으로 만든 것)은 옮기지 않는다
        let bare = CodexAppServer.HookEntry(source: "user", pluginID: nil, event: "Stop", matcher: nil,
                                            command: "x", timeout: 5, trusted: true)
        #expect(CodexAppServer.userGroupsToCarry([bare]).isEmpty)
    }

    @Test func hooks_list_오류_응답은_실패다() {
        #expect(parse(#"{"id":2,"error":{"code":-32601,"message":"nope"}}"#, pending: 2) == .response(id: 2, ok: false))
    }

    // MARK: - WebSocket 프레이밍

    private func serverFrame(opcode: UInt8, payload: [UInt8], fin: Bool = true) -> Data {
        var f = Data([(fin ? 0x80 : 0) | opcode])
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f.append(126); f.append(contentsOf: [UInt8(n >> 8), UInt8(n & 0xff)]) }
        else { f.append(127); f.append(contentsOf: (0..<8).reversed().map { UInt8((n >> ($0 * 8)) & 0xff) }) }
        f.append(contentsOf: payload)
        return f
    }

    @Test func 서버_프레임_해석은_126_127_길이를_다룬다() {
        for size in [5, 125, 126, 4998, 65535, 65536, 70000] {
            let payload = (0..<size).map { UInt8(truncatingIfNeeded: $0 % 251) }
            var data = serverFrame(opcode: 1, payload: payload)
            data.append(contentsOf: [0x81, 0x01])   // 다음 프레임의 앞부분 — 소비하지 않아야 한다
            guard case .frame(let f, let consumed) = CodexWebSocketFrame.decode(data) else {
                Issue.record("size \(size) 해석 실패"); continue
            }
            #expect(f.fin)
            #expect(f.opcode == 1)
            #expect(f.payload == Data(payload), "size \(size)")
            #expect(consumed == data.count - 2, "size \(size)")
        }
    }

    @Test func 덜_온_프레임은_더_기다린다() {
        let full = serverFrame(opcode: 1, payload: Array(repeating: 0x41, count: 300))
        for cut in [0, 1, 2, 3, 4, 100, full.count - 1] {
            #expect(CodexWebSocketFrame.decode(full.prefix(cut)) == .needMore, "cut \(cut)")
        }
        let long = serverFrame(opcode: 1, payload: Array(repeating: 0x41, count: 70000))
        #expect(CodexWebSocketFrame.decode(long.prefix(9)) == .needMore)
    }

    @Test func 클라이언트_프레임은_마스킹된다() {
        let payload = Data(#"{"method":"initialized"}"#.utf8)
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        let f = CodexWebSocketFrame.encode(opcode: 1, payload: payload, mask: mask)
        #expect(f[0] == 0x81)
        #expect(f[1] == 0x80 | UInt8(payload.count))
        #expect(Array(f[2..<6]) == mask)
        let body = Array(f[6...])
        #expect(body.count == payload.count)
        #expect(body.enumerated().map { $1 ^ mask[$0 % 4] } == Array(payload))
        #expect(body != Array(payload))

        // 긴 길이도 마스크 비트 + 확장 길이
        let big = Data(repeating: 0x61, count: 70000)
        let fb = CodexWebSocketFrame.encode(opcode: 1, payload: big, mask: mask)
        #expect(fb[1] == 0x80 | 127)
        #expect(fb.count == 2 + 8 + 4 + 70000)
        let mid = CodexWebSocketFrame.encode(opcode: 1, payload: Data(repeating: 0x61, count: 300), mask: mask)
        #expect(mid[1] == 0x80 | 126)
        #expect(Array(mid[2..<4]) == [0x01, 0x2c])

        // 기본 마스크는 무작위 4바이트이고 해석하면 원래대로 돌아온다
        let r = CodexWebSocketFrame.encode(opcode: 1, payload: payload)
        guard case .frame(let back, let n) = CodexWebSocketFrame.decode(r) else { Issue.record("왕복 실패"); return }
        #expect(back.payload == payload)
        #expect(n == r.count)
    }

    @Test func 너무_큰_프레임은_잘못이다() {
        var f = Data([0x81, 127])
        f.append(contentsOf: [0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        #expect(CodexWebSocketFrame.decode(f) == .invalid)
    }

    @Test func 읽개는_조각을_잇고_ping_close_를_알린다() {
        var reader = CodexWebSocketReader()
        var data = serverFrame(opcode: 1, payload: Array(#"{"id":1,"#.utf8), fin: false)
        data += serverFrame(opcode: 9, payload: [0x01, 0x02])                   // 조각 사이 제어 프레임
        data += serverFrame(opcode: 0, payload: Array(#""result":{}}"#.utf8), fin: true)
        data += serverFrame(opcode: 1, payload: Array(#"{"method":"warning"}"#.utf8))
        // 두 번에 나눠 먹여도 같다
        let split = 7
        var events = reader.feed(data.prefix(split))
        events += reader.feed(data.dropFirst(split))
        #expect(events == [.ping(Data([0x01, 0x02])),
                           .message(Data(#"{"id":1,"result":{}}"#.utf8)),
                           .message(Data(#"{"method":"warning"}"#.utf8))])
        #expect(reader.feed(serverFrame(opcode: 8, payload: [0x03, 0xe8])) == [.close])
    }

    @Test func 읽개는_잘못된_프레임에서_멈춘다() {
        var reader = CodexWebSocketReader()
        // 앞선 조각 없이 이어붙임 프레임
        #expect(reader.feed(serverFrame(opcode: 0, payload: [0x41])) == [.invalid])
        #expect(reader.feed(serverFrame(opcode: 1, payload: [0x41])) == [])   // 멈춘 뒤에는 아무것도 내지 않는다
    }

    @Test func 핸드셰이크_요청과_수락_값() {
        let req = String(decoding: CodexWebSocketFrame.upgradeRequest(key: "dGhlIHNhbXBsZSBub25jZQ=="), as: UTF8.self)
        #expect(req.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(req.contains("\r\nHost: localhost\r\n"))
        #expect(req.contains("\r\nUpgrade: websocket\r\n"))
        #expect(req.contains("\r\nConnection: Upgrade\r\n"))
        #expect(req.contains("\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        #expect(req.contains("\r\nSec-WebSocket-Version: 13\r\n"))
        #expect(req.hasSuffix("\r\n\r\n"))
        // RFC 6455 1.3 의 예
        #expect(CodexWebSocketFrame.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func 핸드셰이크_응답을_검사한다() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let ok = "HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\nsec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nx-codex-websocket-max-unfragmented-message-bytes: 16777216\r\n\r\n"
        var data = Data(ok.utf8)
        data.append(contentsOf: [0x81, 0x00])   // 바로 뒤에 붙어 온 프레임
        #expect(CodexWebSocketFrame.parseHandshake(data, key: key) == .upgraded(consumed: ok.utf8.count))
        #expect(CodexWebSocketFrame.parseHandshake(Data(ok.utf8.prefix(40)), key: key) == .needMore)
        let wrongAccept = ok.replacingOccurrences(of: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", with: "AAAA")
        #expect(CodexWebSocketFrame.parseHandshake(Data(wrongAccept.utf8), key: key)
                == .failed("sec-websocket-accept 불일치"))
        let refused = "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n"
        #expect(CodexWebSocketFrame.parseHandshake(Data(refused.utf8), key: key) == .failed("HTTP/1.1 400 Bad Request"))
    }

    // MARK: - 훅 목록(일회용 stdio 서버) — 진짜 codex 대신 가짜 스크립트

    private func fakeServer(_ lines: [String]) -> [String] {
        // stdin 을 한 줄 읽을 때마다 준비된 줄을 낸다. zsh 시작 잡음 한 줄을 먼저 찍는다.
        let quoted = lines.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "echo 'zshrc noise'; read a; printf '%s\\n' \(quoted[0]); read b; read c; printf '%s\\n' \(quoted.dropFirst().joined(separator: " ")); sleep 5"
        return ["-c", script]
    }

    @Test func 훅_목록은_initialize_뒤_hooks_list_결과를_돌려준다() async {
        let lines = [#"{"id":1,"result":{"userAgent":"dure/0.167.0","codexHome":"/h","platformFamily":"unix","platformOs":"macos"}}"#,
                     #"{"method":"configWarning","params":{}}"#,
                     hooksListResult.replacingOccurrences(of: "\n", with: "")]
        let tmp = FileManager.default.temporaryDirectory.path
        let start = Date()
        let e = await CodexHookInventory.load(cwd: tmp, executable: "/bin/sh", arguments: fakeServer(lines), timeout: 5)
        #expect(e.count == 7)
        #expect(Date().timeIntervalSince(start) < 3)   // 결과를 받으면 서버를 기다리지 않고 끝낸다
    }

    @Test func 훅_목록은_시간이_지나면_빈_배열이다() async {
        let start = Date()
        let e = await CodexHookInventory.load(cwd: "/", executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.5)
        #expect(e.isEmpty)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func 훅_목록은_서버가_실패하면_빈_배열이다() async {
        let e = await CodexHookInventory.load(cwd: "/", executable: "/bin/sh",
                                              arguments: ["-c", "echo '{\"id\":1,\"error\":{\"code\":1,\"message\":\"x\"}}'"], timeout: 5)
        #expect(e.isEmpty)
        let gone = await CodexHookInventory.load(cwd: "/", executable: "/nonexistent/codex", arguments: [], timeout: 5)
        #expect(gone.isEmpty)
    }

    @Test func 훅_목록_기본_명령은_진짜_home_의_stdio_서버다() {
        let script = CodexHookInventory.defaultScript
        #expect(script.hasPrefix("unset DURE_SESSION DURE_AGENT_KIND; exec codex app-server"))
        #expect(!script.contains("CODEX_HOME"))   // 사용자 셸이 정한 진짜 home 을 그대로 쓴다
        #expect(script.contains("check_for_update_on_startup=false"))
        #expect(!script.contains("--listen"))
    }
}
