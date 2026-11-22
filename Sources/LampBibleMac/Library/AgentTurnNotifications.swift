import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI
import UserNotifications

/// Where a finished turn's notification takes the reader when it is clicked.
enum AgentTurnRoute: Equatable, Sendable {
    /// A reader chat, which lives in one window's tab.
    case readerChat(UUID)
    /// A writing's assistant, by the writing's id.
    case writing(String)

    private static let kindKey = "lampTurnRouteKind"
    private static let idKey = "lampTurnRouteID"

    var userInfo: [String: String] {
        switch self {
        case .readerChat(let id): [Self.kindKey: "readerChat", Self.idKey: id.uuidString]
        case .writing(let id): [Self.kindKey: "writing", Self.idKey: id]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[Self.kindKey] as? String,
              let id = userInfo[Self.idKey] as? String else { return nil }
        switch kind {
        case "readerChat":
            guard let chat = UUID(uuidString: id) else { return nil }
            self = .readerChat(chat)
        case "writing":
            guard !id.isEmpty else { return nil }
            self = .writing(id)
        default:
            return nil
        }
    }

    /// One notification per chat: a newer turn's replaces the last one's,
    /// rather than a column of them for one conversation.
    var notificationIdentifier: String {
        switch self {
        case .readerChat(let id): "lamp.agent-turn.reader.\(id.uuidString)"
        case .writing(let id): "lamp.agent-turn.writing.\(id)"
        }
    }
}

/// What a host tells a chat about itself, so a turn that ends while nobody
/// is looking can say whose it was and lead back to it. Kept by the chat
/// when its pane goes, since a reply outlives its pane.
struct AgentTurnNotificationContext: Equatable {
    var title: String
    var route: AgentTurnRoute
}

/// A notification when an agent finishes a turn the reader was not watching:
/// a reader chat or a writing's assistant, in a chat or in Terminal.
///
/// Off until it is turned on in Settings, and only while AI features are on.
/// Not for a turn the reader stopped (they were there), one a phone asked
/// for (they are on the phone), or one stopped because Lamp is quitting.
@MainActor
enum AgentTurnNotifications {
    nonisolated static let enabledKey = "agent.turnNotifications.enabled"
    nonisolated static let showsReplyKey = "agent.turnNotifications.showsReply"
    nonisolated static let categoryIdentifier = "lamp.agent-turn"

    /// How a turn ended, as the notification says it.
    enum Outcome: Equatable {
        case replied(String)
        /// Lamp stopped it: a usage limit, or no word from the agent.
        case stoppedByLamp(String)
        case failed(String)
        /// Ended without a reply and without failing.
        case notice(String)
    }

    static var isEnabledNow: Bool {
        AIFeatures.isEnabledNow && UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// On unless turned off: the start of the reply is the useful part.
    static var showsReplyNow: Bool {
        UserDefaults.standard.object(forKey: showsReplyKey) as? Bool ?? true
    }

    /// Asked when the setting is turned on, never at launch. Once the
    /// person has answered, the system returns that answer without asking.
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posts the notification if the setting is on. Whether anyone was
    /// watching is the caller's to judge.
    static func post(_ outcome: Outcome, context: AgentTurnNotificationContext) {
        guard isEnabledNow, !KeptAgentChats.isQuitting else { return }
        let content = UNMutableNotificationContent()
        content.title = context.title
        content.body = body(for: outcome, showsReply: showsReplyNow)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = context.route.notificationIdentifier
        content.userInfo = context.route.userInfo
        let request = UNNotificationRequest(
            identifier: context.route.notificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    static func body(for outcome: Outcome, showsReply: Bool) -> String {
        switch outcome {
        case .replied(let reply):
            let excerpt = showsReply ? excerpt(of: reply) : ""
            return excerpt.isEmpty ? "Replied." : excerpt
        case .stoppedByLamp(let reason):
            return reason
        case .failed(let failure):
            return "Couldn\u{2019}t finish: \(failure)"
        case .notice(let notice):
            return notice
        }
    }

    /// The reply's opening as plain words: Markdown's marks taken off, links
    /// reduced to their text, and whitespace run together, cut at a word
    /// near `limit` characters. A notification shows two or three lines.
    nonisolated static func excerpt(of markdown: String, limit: Int = 180) -> String {
        var text = markdown
        // Fenced code says nothing in a line or two.
        text = text.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " ", options: .regularExpression)
        // Images go; links keep their text.
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // Line-leading marks: headings, quotes, list bullets and numbers.
        text = text.replacingOccurrences(
            of: "(?m)^[ \\t]*(#{1,6}[ \\t]+|>[ \\t]?|[-*+][ \\t]+|\\d+[.)][ \\t]+)",
            with: "", options: .regularExpression
        )
        // Emphasis and inline code.
        text = text.replacingOccurrences(of: "(\\*\\*|__|\\*|_|`)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "\u{2026}"
    }
}

extension Notification.Name {
    /// A finished turn's notification was clicked. The object is the
    /// `AgentTurnRoute`; each library window looks for it among its own.
    static let lampShowAgentTurn = Notification.Name("lampShowAgentTurn")
}

/// Whether a pane is where the reader is looking: its window is the key
/// window, Lamp is the active app, and the pane has room on screen. A pane
/// folded to no width, a tab behind another or a window in the background
/// is not being watched, and a turn that ends there is worth telling.
struct WatchedPaneProbe: ViewModifier {
    let changed: (Bool) -> Void
    @Environment(\.controlActiveState) private var activeState
    @State private var hasRoom = false
    @State private var isShown = false

    private var watched: Bool { isShown && hasRoom && activeState == .key }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { $0.size.width > 1 && $0.size.height > 1 } action: { hasRoom = $0 }
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .onChange(of: watched, initial: true) { _, now in changed(now) }
    }
}

extension View {
    func reportsWatched(_ changed: @escaping (Bool) -> Void) -> some View {
        modifier(WatchedPaneProbe(changed: changed))
    }
}

/// A library window's answer to a clicked turn notification: a reader chat
/// one of its tabs holds is brought forward in it; a writing is opened by the
/// frontmost library window alone, so two windows do not both open it.
/// Kept out of the library view's body, which is at the type checker's limit.
struct AgentTurnRouteReceiver: ViewModifier {
    /// Shows the chat if this window holds it, and says whether it did.
    let showReaderChat: (UUID) -> Bool
    @Environment(\.openWindow) private var openWindow
    @State private var host = CommandPaletteWindows.Host()

    func body(content: Content) -> some View {
        content
            .background {
                CommandPaletteWindows.Registrar(host: host)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lampShowAgentTurn)) { note in
                guard let route = note.object as? AgentTurnRoute else { return }
                switch route {
                case .readerChat(let chat):
                    if showReaderChat(chat) {
                        host.window?.makeKeyAndOrderFront(nil)
                    }
                case .writing(let id):
                    guard let window = host.window,
                          window === CommandPaletteWindows.target() ?? CommandPaletteWindows.frontmostLibrary()
                    else { return }
                    openWindow(
                        id: "devotional-editor",
                        value: DevotionalEditorRequest(devotionalID: id, opensAgentPane: true)
                    )
                }
            }
    }
}

/// Lamp's notifications while it is open: a finished turn shows even with
/// Lamp frontmost, since it is sent only when its chat is out of view; every
/// other notification keeps the system's default of not showing then. A
/// click on a turn's leads back to its chat.
extension LampAppDelegate: UNUserNotificationCenterDelegate {
    /// Before launch finishes, so a click that launches Lamp is heard too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier
            ? [.banner, .sound, .list]
            : []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier,
              let route = AgentTurnRoute(userInfo: content.userInfo) else { return }
        await MainActor.run {
            NSApp.activate()
            NotificationCenter.default.post(name: .lampShowAgentTurn, object: route)
        }
    }
}
