import SwiftUI

/// 진입점. 이슈 #29 — 유닛 테스트 호스트로 뜨면 앱 본체를 시작하지 않는다.
/// 본체가 뜨면 실제 DB 를 열어 마이그레이션하고, `~/.dure/events` 의 훅 이벤트를 읽고 지워 실행 중인 진짜 두레가 놓치고,
/// 워크스페이스 폴더 · 훅 shim 을 쓴다. 곳곳에 "테스트면 건너뛰기" 를 붙이지 않고 여기 한 곳에서 막는다.
@main
enum DureMain {
    static func main() {
        if TestHost.isActive { TestHostApp.main() } else { DureApp.main() }
    }
}

/// 테스트 호스트 — 창도 저장소도 없다. 테스트는 `@testable import` 로 타입만 쓴다.
struct TestHostApp: App {
    var body: some Scene { Settings { EmptyView() } }
}

struct DureApp: App {
    /// 이슈 #23 — 메인 창과 감시자 창이 같은 스토어를 본다.
    @State private var observer = ObserverStore()

    /// 앱 본체가 시작됐나(테스트가 "테스트 호스트에서는 안 뜬다" 를 확인한다).
    static private(set) var didLaunch = false

    init() {
        Self.didLaunch = true
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
