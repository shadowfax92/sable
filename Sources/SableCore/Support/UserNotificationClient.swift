import Foundation
import UserNotifications

public final class UserNotificationClient: NSObject, UNUserNotificationCenterDelegate {
    public override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Sends a concise macOS notification for Sable run status.
    public func send(title: String, body: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body {
            content.body = body
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
