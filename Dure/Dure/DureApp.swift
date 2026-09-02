import SwiftUI

@main
struct DureApp: App {

    init() {
        // F3 — 터미널을 하나라도 띄우기 전에 shim 과 훅 설정 파일이 있어야 한다.
        // 덮어쓰기라 몇 번 불려도 결과가 같고, 앱 업데이트 시 shim 이 낡은 채로 남지 않는다.
        // 실패해도 앱은 뜬다. 훅이 없으면 관측이 안 될 뿐 터미널은 정상 동작한다.
        do { try HookBridge.install() }
        catch { NSLog("[Dure] 훅 브리지 설치 실패: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            // 1차에서는 탭·분할 명령을 두지 않는다 (ADR-13).
            CommandGroup(replacing: .newItem) {}
        }
    }
}
