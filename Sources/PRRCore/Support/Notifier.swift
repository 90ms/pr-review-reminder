import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Thin wrapper over user notifications. Only functions inside a proper `.app`
/// bundle; calls are best-effort and silently no-op otherwise.
public enum Notifier {
    public static func requestAuthorization() {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    public static func notify(title: String, body: String) {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        #endif
    }
}
