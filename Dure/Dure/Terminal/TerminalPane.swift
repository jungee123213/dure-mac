import SwiftUI
import SwiftTerm

/// ADR-13 — 터미널은 앱 안에 내장한다. 앱이 PTY 와 자식 프로세스를 소유한다.
/// 1차는 세로 스택 N-페인. 탭·스플리터·재배치 없음.
struct TerminalPane: NSViewRepresentable {
    let repo: Repo
    /// ADR-14 의 게이트 값. 페인 하나당 하나이며 앱이 만든다.
    let sessionID: String
    /// F10a — 출발할 때 함께 넘길 브리핑. `claude "<prompt>"` 인자가 된다.
    var initialPrompt: String? = nil
    /// D-27 — 숨긴 층의 페인인가. 숨긴 터미널이 first responder 로 남아 있으면
    /// **타이핑이 안 보이는 페인으로 들어간다.**
    var isActive: Bool = true
    /// PTY 가 죽으면 부른다. F4 의 `dead` 는 훅이 아니라 이 경로로 들어온다.
    var onExit: (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

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
            args: Spawn.shellArgs + [
                Spawn.script(repoPath: repo.path, sessionID: sessionID,
                             initialPrompt: initialPrompt)
            ]
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 1차에서는 재구성하지 않는다. 프로세스는 makeNSView 에서 한 번만 띄운다.
        // D-27 — 숨겨지는 순간 키 입력을 놓는다. 다시 보일 때는 사람이 클릭해서 가져간다.
        if !isActive, nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    /// Step 0-A 실측 — claude 의 OSC 타이틀이 여기로 올라온다 (F4 보조 신호, 아직 안 쓴다).
    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private let onExit: (Int32?) -> Void
        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        /// **F4 의 `dead` 진입점.** 앱이 PTY 를 소유하므로(ADR-13) 훅보다 이쪽이 확실하다.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            NSLog("[Dure] PTY 종료 exitCode=\(exitCode.map(String.init) ?? "nil")")
            onExit(exitCode)
        }
    }
}
