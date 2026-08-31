import SwiftUI

@main
struct DureApp: App {
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
