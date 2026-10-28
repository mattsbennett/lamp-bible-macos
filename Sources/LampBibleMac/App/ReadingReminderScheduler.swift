#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import UserNotifications

enum ReadingReminderScheduler {
    static let identifier = "com.neus.lamp-bible.daily-reading"

    /// Puts the reminder back if it is wanted and the system no longer holds
    /// it.
    ///
    /// The trigger repeats, so once scheduled it survives quitting and
    /// restarting and nothing needs doing. What is not covered is the request
    /// going missing while the switch stays on — most reachably when the
    /// reminder is turned on and the notification prompt is declined, since
    /// nothing is scheduled then and the switch still reads "on". Granting
    /// permission later in System Settings changed nothing, and the reminder
    /// never came. Reconciling at launch is what closes that.
    ///
    /// Re-asking for authorization is safe: once the person has answered,
    /// `requestAuthorization` returns their answer rather than asking again.
    static func reapplyIfMissing(_ configuration: ReadingReminderConfiguration) async {
        guard configuration.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !pending.contains(where: { $0.identifier == identifier }) else { return }
        // Silent: nobody asked for this, so a failure is not something to
        // interrupt a launch with. The Sync pane reports it when touched.
        try? await apply(configuration)
    }

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
