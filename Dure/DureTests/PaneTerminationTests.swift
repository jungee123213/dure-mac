import Foundation
import Testing
@testable import Dure

/// Task 7 fix 1 — Codex 서버가 먼저 죽으면 TUI 는 "Reconnecting…" 으로 남는다.
/// 뷰를 트리에서 빼는 것만으로는 PTY 가 끝나지 않는다(`terminateOnDismantle` 은 꺼져 있다 — D-27).
/// 그래서 스토어가 그 페인의 터미널에 "끝내라" 를 요청하고, 터미널이 끝나며 `markDead` 가 요청을 지운다.
@MainActor
struct PaneTerminationTests {

    @Test func 지금_세션의_서버가_죽고_터미널이_살아_있으면_터미널에_끝내기를_요청한다() {
        #expect(PaneTermination.onServerExit(exitedSession: "s1", paneSession: "s1", terminalLive: true) == .endTerminal)
    }

    @Test func 터미널이_없으면_바로_markDead_한다() {
        #expect(PaneTermination.onServerExit(exitedSession: "s1", paneSession: "s1", terminalLive: false) == .markDead)
    }

    /// 다시 시작해 새 세션이 걸린 뒤 옛 서버의 종료가 늦게 왔다 — 새 페인을 건드리면 안 된다.
    @Test func 옛_세션의_서버_종료는_무시한다() {
        #expect(PaneTermination.onServerExit(exitedSession: "old", paneSession: "new", terminalLive: true) == .ignore)
        #expect(PaneTermination.onServerExit(exitedSession: "old", paneSession: nil, terminalLive: false) == .ignore)
    }

    @Test func 요청은_그_페인_키에만_남고_markDead_가_지운다() {
        var r = PaneTermination.Requests()
        r.request("repo:r1")
        #expect(r.contains("repo:r1"))
        #expect(!r.contains("repo:r2"))
        #expect(!r.contains("orch:w1"))
        r.request("repo:r1")                 // 두 번 와도 하나
        #expect(r.keys == ["repo:r1"])
        r.clear("repo:r1")                   // markDead · start 가 부른다
        #expect(!r.contains("repo:r1"))
        r.clear("repo:r1")                   // 없는 것을 지워도 안전
        #expect(r.keys.isEmpty)
    }

    /// 서버가 죽은 뒤 런타임이 부르는 콜백이 실제로 요청으로 이어지는 길 — 스토어의 반응과 같은 순서로 묶는다.
    @Test func 서버_종료_반응을_요청에_반영하면_그_키가_기록되고_markDead_뒤_비워진다() {
        var r = PaneTermination.Requests()
        var markedDead: [String] = []
        func serverExited(key: String, session: String, pane: String?, live: Bool) {
            switch PaneTermination.onServerExit(exitedSession: session, paneSession: pane, terminalLive: live) {
            case .endTerminal: r.request(key)
            case .markDead: markedDead.append(session)
            case .ignore: break
            }
        }
        serverExited(key: "repo:r1", session: "s1", pane: "s1", live: true)
        serverExited(key: "orch:w1", session: "s9", pane: "s9", live: false)
        serverExited(key: "repo:r2", session: "old", pane: "new", live: true)
        #expect(r.keys == ["repo:r1"])
        #expect(markedDead == ["s9"])
        r.clear("repo:r1")
        #expect(r.keys.isEmpty)
    }
}
