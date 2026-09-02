import Foundation
import UserNotifications

/// F5 — 사람 손이 필요한 순간에만 알린다.
///
/// **울릴 때보다 안 울릴 때가 중요하다.** 가만히 둔 세션마다 60초에 한 번씩 뜨면
/// 사용자는 알림을 꺼버리고, 그러면 F5 는 있으나 마나가 된다.
/// 어떤 이벤트를 알릴지 거르는 책임은 `DureStore` 에 있고, 여기는 띄우기만 한다.
@MainActor
enum Notifier {

    /// 권한이 없거나 거부돼도 앱은 정상 동작해야 한다. 알림만 안 뜬다.
    private(set) static var authorized = false
    private static let delegate = ForegroundPresenter()

    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                authorized = granted
                if let error { NSLog("[Dure] 알림 권한 요청 실패: \(error)") }
            }
        }
    }

    /// - Parameter dureSession: 알림을 눌렀을 때 어느 페인인지 알기 위해 실어 보낸다.
    static func post(title: String, body: String, dureSession: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["dure_session": dureSession]

        // trigger 가 nil 이면 즉시 전달된다.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("[Dure] 알림 전달 실패: \(error)") }
        }
    }

    /// macOS 는 앱이 앞에 떠 있으면 배너를 **기본적으로 띄우지 않는다.**
    /// 두레는 창을 띄워둔 채 다른 일을 하는 도구라, 앞에 있어도 보여야 의미가 있다.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
            handler([.banner, .sound])
        }
    }
}
