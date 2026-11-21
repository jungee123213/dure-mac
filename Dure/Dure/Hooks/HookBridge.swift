import Foundation

/// 앱이 띄우는 에이전트 종류.
/// 둘 다 띄운다. Codex 는 페인마다 app-server 를 거친다 (D-44).
/// 이벤트 줄에 이 값이 들어가므로 **지금** 넣는다. 나중에 포맷을 바꾸면 이미 쌓인 줄과 섞인다.
/// `nonisolated` — 감시자 표(`ObsTurn.agentKind`)가 백그라운드 수집에서 쓴다.
nonisolated enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex
}

/// F3 — 에이전트 세션에서 일어난 일을 앱으로 흘려보내는 통로.
///
/// **사용자의 전역 설정(`~/.claude/settings.json`)을 건드리지 않는다.**
/// `claude --settings <파일>` 로 세션에만 훅을 얹는다 (DECISIONS.md D-1).
/// 대화형 PTY 세션에서 훅 4종이 전부 발화하고 `/clear` 가 재발화하는 것까지 실측했다.
///
/// 그 결과 설계문서 Step 3 가 요구하던 백업·이어붙이기·제거 마커·멱등성 판정·
/// 설치 여부 확인이 **전부 필요 없다.** 앱이 안 띄우면 훅 자체가 존재하지 않는다.
///
/// Codex 도 세션에만 훅을 얹는다 — 서버를 `codex app-server -c hooks.*` 로 띄우고 신뢰 표(`hooks.state`)를
/// 함께 준다(`CodexHooks`, D-44). 전역 `~/.codex/` 는 건드리지 않아 이어붙이기 기계장치가 필요 없다.
enum HookBridge {

    // MARK: - 경로

    static let home = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".dure", isDirectory: true)

    static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    static var shimURL: URL { binDir.appendingPathComponent("hook") }
    /// 이벤트 하나당 파일 하나. `events.jsonl` 공유 append 를 쓰지 않는 이유는 shimSource 주석 참조.
    static var eventsDir: URL { home.appendingPathComponent("events", isDirectory: true) }

    /// ADR-17 의 1차 훅 4종. `PreToolUse` 는 1차에 설치하지 않는다
    /// (툴 로그는 트랜스크립트에 이미 있고, 모든 툴 호출에 프로세스 spawn 비용이 붙는다).
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "Notification", "Stop"]

    // MARK: - 설치

    /// 앱 시작 시 한 번 호출한다. 덮어쓰기이므로 몇 번을 불러도 결과가 같다.
    /// 앱을 업데이트했을 때 shim 이 낡은 채로 남지 않게 매번 최신 내용을 쓴다.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        try Data(shimSource.utf8).write(to: shimURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        // #16 — 페인 종류별 설정. 레포 페인용은 내용이 고정이라 시작 때 쓴다.
        // 조율자용은 레포 목록이 바뀌므로 조율자를 띄울 때마다 쓴다 (SessionSettings.writeOrchestrator).
        try SessionSettings.writeRepoPane()
        // 예전 공용 파일. 더는 아무도 읽지 않는다.
        try? fm.removeItem(at: home.appendingPathComponent("hooks.json"))
    }

    /// `--settings` 의 `"hooks"` 값. 페인 종류별 설정 파일이 이것을 공통으로 담는다 (#16).
    ///
    /// **이벤트 이름을 shim 의 인자로 넘긴다.** 이게 핵심이다 —
    /// shim 이 stdin JSON 을 파싱하지 않고도 무슨 이벤트인지 알 수 있어서,
    /// 훅 스크립트에 `jq` 같은 외부 의존이 하나도 없다.
    static func hooksObject() -> [String: Any] {
        let quoted = "'" + shimURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var hooks: [String: Any] = [:]
        for event in hookEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "\(quoted) \(event)",
                    // shim 이 어떤 이유로 멈춰도 에이전트가 같이 멈추지 않게 한다.
                    "timeout": 5
                ]]
            ]]
        }
        return hooks
    }

    /// 훅만 담은 설정. 테스트와 진단용으로 남긴다 — 실제 스폰은 `SessionSettings` 의 파일을 쓴다.
    static func settingsJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hooks": hooksObject()],
                                   options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - shim

    /// 훅이 실행하는 POSIX 셸 스크립트.
    ///
    /// 설계 근거:
    /// - **stdin 을 파싱하지 않는다.** 받은 JSON 을 `payload` 값으로 그대로 끼워넣는다.
    ///   유효한 JSON 을 JSON 값 자리에 넣는 것이므로 이스케이프가 필요 없고,
    ///   에이전트가 나중에 필드를 추가해도 그대로 따라온다.
    /// - **`UserPromptSubmit` · `PostToolUse` 는 payload 를 버린다.** 앞쪽에는 사용자가 친 프롬프트 전문이,
    ///   뒤쪽(Codex)에는 툴 출력 전문이 들어와 길이가 무제한이다. 상태 판정에는 "누가 언제 제출했나"면 충분하다.
    ///   어느 cc_session 인지는 앱이 "가장 최근 SessionStart" 로 판정한다 (부록 A4 주석).
    /// - **이벤트 하나당 파일 하나 + 원자적 rename.** 설계문서 부록 A2 는 `events.jsonl` 에
    ///   공유 append 하고 "단일 write + 4KB 이하면 실무적으로 안전"하다고 적었는데,
    ///   **실측에서 깨졌다.** 300회 동시 호출 중 2줄이 정확히 1024바이트 경계에서 찢어졌다.
    ///   `/bin/sh` 의 `printf` 가 stdout 을 1024바이트 단위로 버퍼링해 한 줄이 여러 번의
    ///   `write()` 로 나가기 때문이다. 실제 `SessionStart` 줄이 이미 952바이트라 한도를
    ///   1KB 로 낮추는 것으로는 못 막는다. 파일을 나누면 이 문제 부류가 통째로 사라지고,
    ///   A2 가 유실 경로를 스스로 인정했던 8MB 로테이션도 필요 없어진다.
    /// - `DURE_SESSION` 게이트는 지금은 방어적 잉여다(세션 단위 주입이라 앱 세션에만 붙는다).
    ///   **그래도 남긴다** — Codex 는 전역 훅뿐이라 그때 이 줄이 유일한 방어선이 된다 (ADR-14).
    static let shimSource = #"""
    #!/bin/sh
    # Dure 훅 shim — 앱이 생성한다. 직접 고치지 말 것 (앱 시작 시 덮어쓴다).
    # 이벤트 이름은 인자로 받는다. stdin JSON 을 파싱하지 않으므로 외부 의존이 없다.

    EV=${1:-unknown}

    # ADR-14 — 앱이 띄운 세션만 앱의 관할이다.
    # `[ -z "$X" ] && exit 0` 형태를 쓰지 않는다. X 가 설정된 경우 compound 가 false 를
    # 반환해 스크립트가 의도치 않은 non-zero 로 끝난다.
    if [ -z "$DURE_SESSION" ]; then exit 0; fi

    # stdin 은 어떤 경로로든 반드시 비운다. 안 읽으면 에이전트가 write 에러를 볼 수 있다.
    PAYLOAD=$(cat)

    EVDIR="$HOME/.dure/events"
    umask 077
    if [ ! -d "$EVDIR" ]; then mkdir -p "$EVDIR" || exit 0; fi

    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    KIND=${DURE_AGENT_KIND:-claude}
    HEAD="{\"v\":1,\"ts\":\"$TS\",\"ev\":\"$EV\",\"agent_kind\":\"$KIND\",\"dure_session\":\"$DURE_SESSION\""

    case "$EV" in
      UserPromptSubmit|PostToolUse) BODY="$HEAD}" ;;
      *)                BODY="$HEAD,\"payload\":$PAYLOAD}" ;;
    esac

    # 파일명이 곧 정렬 키다. 나노초가 없는 환경이면 초로 떨어뜨린다.
    SEQ=$(date -u +%s%N)
    case "$SEQ" in *[!0-9]*|"") SEQ="$(date -u +%s)000000000" ;; esac
    BASE="$EVDIR/$SEQ-$$-${RANDOM:-0}"

    # `.tmp` 에 쓰고 rename 한다. 앱은 `.json` 만 읽으므로 절반 쓰인 파일을 볼 수 없다.
    # 같은 디렉토리 안의 rename 이라 원자적이다.
    if printf '%s\n' "$BODY" > "$BASE.tmp" 2>/dev/null; then
      mv "$BASE.tmp" "$BASE.json" 2>/dev/null || rm -f "$BASE.tmp"
    fi
    exit 0
    """#
}
