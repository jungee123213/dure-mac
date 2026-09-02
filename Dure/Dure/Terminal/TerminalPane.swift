import SwiftUI
import SwiftTerm

/// ADR-13 — 터미널은 앱 안에 내장한다. 앱이 PTY 와 자식 프로세스를 소유한다.
/// 1차는 세로 스택 N-페인. 탭·스플리터·재배치 없음.
struct TerminalPane: NSViewRepresentable {
    let repo: Repo
    /// ADR-14 의 게이트 값. 페인 하나당 하나이며 앱이 만든다.
    let sessionID: String
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
        view.inputContext?.activate()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.inputContext?.activate()
        }

        view.startProcess(
            executable: Spawn.shell,
            args: Spawn.shellArgs + [
                Spawn.script(repoPath: repo.path, sessionID: sessionID, model: repo.model)
            ]
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 1차에서는 재구성하지 않는다. 프로세스는 makeNSView 에서 한 번만 띄운다.
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
