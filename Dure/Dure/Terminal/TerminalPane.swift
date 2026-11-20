import SwiftUI
import SwiftTerm

/// ADR-13 — 터미널은 앱 안에 내장한다. 앱이 PTY 와 자식 프로세스를 소유한다.
/// 1차는 세로 스택 N-페인. 탭·스플리터·재배치 없음.
struct TerminalPane: NSViewRepresentable {
    /// `Spawn.script(…)` 가 만든 셸 스크립트. 레포 페인인지 조율자인지는 스토어가 정한다 (#16).
    let script: String
    /// D-27 — 숨긴 층의 페인인가. 숨긴 터미널이 first responder 로 남아 있으면
    /// **타이핑이 안 보이는 페인으로 들어간다.**
    var isActive: Bool = true
    /// PTY 가 죽으면 부른다. F4 의 `dead` 는 훅이 아니라 이 경로로 들어온다.
    var onExit: (Int32?) -> Void = { _ in }
    /// SwiftUI 가 이 뷰를 걷어낼 때 프로세스도 끝낼까. 레포 · 조율자 페인은 **끄지 않는다**(기본값) —
    /// 층을 바꿔도 페인이 살아 있어야 하고(D-27) 종료는 사람이 claude 안에서 한다. 감시자 묻기 페인만 켠다:
    /// 닫기 = 대화 끝이고, 안 끄면 보이지 않는 claude 가 남는다.
    var terminateOnDismantle = false
    /// 스토어가 이 페인을 끝내라고 요청했다(Codex 서버가 먼저 죽음 — `PaneTermination`). 참이 되면 PTY 를 끝내고
    /// `onExit` 를 부른다. 걷어낼 때 끄는 것(`terminateOnDismantle`)과 다르다 — 층 전환은 페인을 살려 둔다(D-27).
    var terminateRequested = false

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit, terminateOnDismantle: terminateOnDismantle) }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if coordinator.terminateOnDismantle { nsView.terminate() }
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 240))
        view.processDelegate = context.coordinator

        // Step 0-A / A-4a — 새 터미널의 첫 한글 조합에서 첫 음절이 자모로 쪼개져
        // 전송되는 SwiftTerm 버그 대응. 첫 키 이벤트가 도착하기 전에 IME 세션을 세워둔다.
        // `becomeFirstResponder` 는 SwiftTerm 이 `public`(not `open`) 으로 선언해
        // 서브클래스에서 오버라이드할 수 없으므로 앱 쪽에서 선점한다.
        // ⚠️ 여기서 바로 `inputContext?.activate()` 를 부르지 않는다 (이슈 #12 크래시).
        // makeNSView 는 SwiftUI 가 화면을 만드는 **도중**이다. 그때 다른 입력칸(사이드바 역할 칸)이
        // 한글 입력 세션을 쥐고 있으면, 활성화가 그 세션을 끊어 조합 중이던 글자를 확정시키고
        // 입력칸 값이 바뀐다 → 갱신 중 상태 변경 → AttributeGraph 순환 → 이 뷰가 두 번 만들어지고
        // (claude 도 두 개) 버려진 뷰를 건드려 크래시. 활성화는 아래 비동기 블록에서 한다.
        // 최종 리뷰 F1 — 숨긴 채로 만들어진 페인(대시보드 아래·다른 워크스페이스 층)이
        // 여기서 포커스를 가져가면 **키 입력이 안 보이는 claude 로 들어간다.**
        // updateNSView 의 해제보다 이 블록이 늦게 돌기 때문에 여기서도 막아야 한다.
        let active = isActive
        DispatchQueue.main.async {
            guard active else { return }
            view.window?.makeFirstResponder(view)
            view.inputContext?.activate()
        }

        view.startProcess(
            executable: Spawn.shell,
            args: Spawn.shellArgs + [script]
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 1차에서는 재구성하지 않는다. 프로세스는 makeNSView 에서 한 번만 띄운다.
        // D-27 — 숨겨지는 순간 키 입력을 놓는다. 다시 보일 때는 사람이 클릭해서 가져간다.
        if !isActive, nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
        if terminateRequested { context.coordinator.end(nsView) }
    }

    /// Step 0-A 실측 — claude 의 OSC 타이틀이 여기로 올라온다 (F4 보조 신호, 아직 안 쓴다).
    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private let onExit: (Int32?) -> Void
        let terminateOnDismantle: Bool
        /// `onExit` 는 한 번만 — 요청으로 끝낸 뒤 진짜 종료 신호가 와도 두 번 부르지 않는다.
        private var exited = false
        init(onExit: @escaping (Int32?) -> Void, terminateOnDismantle: Bool) {
            self.onExit = onExit
            self.terminateOnDismantle = terminateOnDismantle
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        /// **F4 의 `dead` 진입점.** 앱이 PTY 를 소유하므로(ADR-13) 훅보다 이쪽이 확실하다.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            NSLog("[Dure] PTY 종료 exitCode=\(exitCode.map(String.init) ?? "nil")")
            guard !exited else { return }
            exited = true
            onExit(exitCode)
        }

        /// 요청받은 종료. SwiftTerm `LocalProcess.terminate()` 는 SIGTERM 을 보내면서 자식 감시를 **취소**해
        /// `processTerminated` 가 오지 않는다 — 그래서 `onExit` 를 여기서 부른다. `updateNSView` 안이라
        /// (그리는 중 상태 변경을 피해) 다음 런루프로 미룬다.
        func end(_ view: LocalProcessTerminalView) {
            guard !exited else { return }
            exited = true
            NSLog("[Dure] PTY 종료 요청")
            view.terminate()
            let onExit = onExit
            DispatchQueue.main.async { onExit(nil) }
        }
    }
}
