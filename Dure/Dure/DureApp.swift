import SwiftUI

@main
struct DureApp: App {
    /// 이슈 #23 — 메인 창과 감시자 창이 같은 스토어를 본다.
    @State private var observer = ObserverStore()

    init() {
        // F3 — 터미널을 하나라도 띄우기 전에 shim 과 훅 설정 파일이 있어야 한다.
        // 덮어쓰기라 몇 번 불려도 결과가 같고, 앱 업데이트 시 shim 이 낡은 채로 남지 않는다.
        // 실패해도 앱은 뜬다. 훅이 없으면 관측이 안 될 뿐 터미널은 정상 동작한다.
        do { try HookBridge.install() }
        catch { NSLog("[Dure] 훅 브리지 설치 실패: \(error)") }

        // F5 — 권한을 거부해도 앱은 정상 동작한다. 알림만 안 뜬다.
        Notifier.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(observer: observer)
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            // 1차에서는 탭·분할 명령을 두지 않는다 (ADR-13).
            CommandGroup(replacing: .newItem) {}
            ObserverCommands()
        }

        // 감시자는 워크스페이스에 속하지 않는다 — 별도 창(D-25 와 같은 이유: 듀얼 모니터에서 옆에 둔다).
        Window("감시자", id: "observer") {
            ObserverView(observer: observer)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

struct ObserverCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("감시자") { openWindow(id: "observer") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
