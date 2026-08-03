#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import UserNotifications

enum ReadingReminderScheduler {
    static let identifier = "com.neus.lamp-bible.daily-reading"

    static func apply(_ configuration: ReadingReminderConfiguration) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard configuration.isEnabled else { return }

        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw ReadingReminderError.permissionDenied }

        let content = UNMutableNotificationContent()
        content.title = "Lamp Bible"
        content.body = "Your reading plan is ready for today."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: configuration.dateComponents,
            repeats: true
        )
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        ))
    }
}

enum ReadingReminderError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "Notifications are disabled for Lamp Bible. Enable them in System Settings to use reading reminders."
    }
}
