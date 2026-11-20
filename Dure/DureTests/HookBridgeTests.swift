import Foundation
import Testing
@testable import Dure

/// F3 — shim 과 훅 설정이 계약대로 생성되는지.
/// 여기서 깨지면 훅이 조용히 발화하지 않고, 그러면 상태·토큰·알림이 전부 죽는다.
struct HookBridgeTests {

    @Test func shim은_셸_스크립트로_시작한다() {
        let lines = HookBridge.shimSource.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "#!/bin/sh")
    }

    /// ADR-14 — 앱이 띄운 세션만 앱의 관할이다.
    /// `[ -z "$X" ] && exit 0` 형태는 X 가 설정된 경우 compound 가 false 를 반환해
    /// 스크립트가 의도치 않은 non-zero 로 끝난다. 반드시 `if` 형태여야 한다.
    @Test func 게이트는_if_형태다() {
        // 주석에는 안티패턴 설명이 일부러 들어 있으므로 **코드 줄만** 본다.
        let code = HookBridge.shimSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        #expect(code.contains(#"if [ -z "$DURE_SESSION" ]; then exit 0; fi"#))
        #expect(!code.contains("&& exit 0"))
    }

    /// 이벤트 하나당 파일 하나 + 원자적 rename.
    /// 공유 append 는 실측에서 1024바이트 경계에 줄이 찢어졌다 (DECISIONS.md D-6).
    @Test func 이벤트를_파일_단위로_원자적으로_쓴다() {
        let src = HookBridge.shimSource
        #expect(src.contains(#"> "$BASE.tmp""#))
        #expect(src.contains(#"mv "$BASE.tmp" "$BASE.json""#))
        // 공유 append 로 되돌아가면 여기서 걸린다.
        #expect(!src.contains(">> \"$EVDIR"))
        #expect(!src.contains("events.jsonl"))
    }

    /// 프롬프트 전문은 길이가 무제한이고 상태 판정에 필요 없다. 어느 세션인지는
    /// 앱이 "가장 최근 SessionStart" 로 판정한다 (부록 A4 주석).
    @Test func 프롬프트_전문은_기록하지_않는다() {
        #expect(HookBridge.shimSource.contains("UserPromptSubmit|PostToolUse) BODY=\"$HEAD}\""))
    }

    /// Codex 의 PostToolUse payload 에는 툴 출력 전문이 실려 크다.
    @Test func shim_은_PostToolUse_의_payload_를_버린다() {
        #expect(HookBridge.shimSource.contains("PostToolUse) BODY=\"$HEAD}\""))
    }

    @Test func 이벤트_디렉토리_경로() {
        #expect(HookBridge.eventsDir.path.hasSuffix("/.dure/events"))
    }

    @Test func 훅_4종이_shim을_가리킨다() throws {
        let data = try HookBridge.settingsJSON()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])

        #expect(Set(hooks.keys) == Set(HookBridge.hookEvents))
        #expect(hooks.count == 4)

        for event in HookBridge.hookEvents {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let entries = try #require(groups.first?["hooks"] as? [[String: Any]])
            let entry = try #require(entries.first)
            let command = try #require(entry["command"] as? String)

            // 이벤트 이름을 인자로 넘기기 때문에 shim 이 stdin 을 파싱하지 않아도 된다.
            #expect(command.hasSuffix(" \(event)"))
            #expect(command.contains(HookBridge.shimURL.path))
            #expect(entry["timeout"] as? Int == 5)
        }
    }

    /// 사용자의 전역 설정을 읽지도 쓰지도 않는다는 것이 이 기능의 성격이다.
    @Test func 전역_설정_경로를_참조하지_않는다() throws {
        let json = String(decoding: try HookBridge.settingsJSON(), as: UTF8.self)
        #expect(!json.contains(".claude/settings.json"))
    }

    /// D-3 — 이벤트 줄에 에이전트 종류가 들어간다. 포맷을 나중에 바꾸면 쌓인 줄과 섞인다.
    @Test func 스폰_명령이_세션_훅과_종류를_주입한다() {
        let s = Spawn.script(cwd: "/tmp/repo", sessionID: "uuid-1", settingsPath: SessionSettings.repoPaneURL().path, sessionName: "n")
        #expect(s.contains("export DURE_SESSION='uuid-1'"))
        #expect(s.contains("export DURE_AGENT_KIND='claude'"))
        #expect(s.contains("--settings '\(SessionSettings.repoPaneURL().path)'"))
        #expect(s.contains("exec claude"))
    }

    /// 레포 경로에 작은따옴표가 있어도 셸이 깨지지 않아야 한다.
    @Test func 경로_인용이_안전하다() {
        let s = Spawn.script(cwd: "/tmp/it's here", sessionID: "u", settingsPath: SessionSettings.repoPaneURL().path, sessionName: "n")
        #expect(s.contains(#"cd '/tmp/it'\''s here'"#))
    }
}
