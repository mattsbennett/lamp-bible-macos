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
    enum Outcome: Equatable, Sendable {
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

    /// Posts the notification if the setting is on, saying whether it did.
    /// Whether anyone was watching is the caller's to judge.
    ///
    /// `waitingProvider`: a turn of that provider's waiting on an answer,
    /// under a name of its own, so taking it back can't take another turn's
    /// end, or another provider's wait, with it.
    @discardableResult
    static func post(_ outcome: Outcome, context: AgentTurnNotificationContext, waitingProvider: String? = nil) -> Bool {
        let isWait = waitingProvider != nil
        guard isEnabledNow, !KeptAgentChats.isQuitting else { return false }
        let content = UNMutableNotificationContent()
        content.title = context.title
        content.body = body(for: outcome, showsReply: showsReplyNow)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = context.route.notificationIdentifier
        content.userInfo = context.route.userInfo.merging(isWait ? [Self.waitKey: "1"] : [:]) { $1 }
        let request = UNNotificationRequest(
            identifier: waitingProvider.map { waitIdentifier(context, provider: $0) } ?? context.route.notificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
        return true
    }

    /// Takes back a notification still shown for the chat: one that said a
    /// turn waited, once it doesn't.
    static func withdraw(context: AgentTurnNotificationContext, provider: String) {
        // Not yet shown too: adding one is asynchronous, and an answer can
        // come first.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [waitIdentifier(context, provider: provider)])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [waitIdentifier(context, provider: provider)])
    }

    /// Marks a wait's notice.
    nonisolated static let waitKey = "lampTurnIsWait"

    static func waitIdentifier(_ context: AgentTurnNotificationContext, provider: String) -> String {
        context.route.notificationIdentifier + ".waiting." + provider
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
    /// The writing editor showing this writing (the object, its id) shows
    /// its assistant.
    static let lampShowWritingAssistant = Notification.Name("lampShowWritingAssistant")
    /// A finished turn's notification was clicked. The object is the
    /// `AgentTurnRoute`; each library window looks for it among its own.
    static let lampShowAgentTurn = Notification.Name("lampShowAgentTurn")
}

/// Whether a pane is where the reader is looking, asked at the moment a
/// turn ends rather than tracked: Lamp is active, the pane's window is the
/// key window, and the pane is drawn there with room. A reader tab behind
/// another is hidden at the AppKit level (`ReaderTabHosts`) and never told
/// so in SwiftUI, and a pane folded to no width keeps its views, so only
/// the view itself can say whether it is seen.
@MainActor
final class PaneVisibility {
    fileprivate weak var view: NSView?
    /// Hidden by its host though still drawn: a writing's chat kept mounted,
    /// unseen, behind its Terminal.
    var isHiddenByHost = false

    var isWatched: Bool {
        guard !isHiddenByHost, NSApp.isActive, let view, let window = view.window,
              window.isKeyWindow, window.isVisible, !window.isMiniaturized,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        let shown = view.visibleRect
        return shown.width > 1 && shown.height > 1
    }

    /// The window the pane is drawn in with room, whether or not it is in
    /// front: what a click on a notification brings forward. Nil for a pane
    /// folded away or in a tab behind another.
    var shownWindow: NSWindow? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let shown = view.visibleRect
        return shown.width > 1 && shown.height > 1 ? window : nil
    }
}

/// Puts a pane's `PaneVisibility` on a view that fills it.
private struct PaneVisibilityProbe: NSViewRepresentable {
    let visibility: PaneVisibility

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        visibility.view = probe
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        visibility.view = probe
    }
}

extension View {
    func reportsVisibility(to visibility: PaneVisibility) -> some View {
        background {
            PaneVisibilityProbe(visibility: visibility)
                .accessibilityHidden(true)
        }
    }
}

/// The writing panes showing a running Terminal session, by writing, so a
/// Terminal turn, which any pane on the writing may be the one to read in,
/// is quiet if one that shows the conversation is seen.
@MainActor
enum WritingPaneVisibility {
    private static var panes: [String: [AnyHashable: PaneVisibility]] = [:]

    static func register(_ visibility: PaneVisibility, writingID: String, token: AnyHashable) {
        panes[writingID, default: [:]][token] = visibility
    }

    static func unregister(writingID: String, token: AnyHashable) {
        panes[writingID]?[token] = nil
        if panes[writingID]?.isEmpty == true { panes[writingID] = nil }
    }

    static func isWatched(writingID: String) -> Bool {
        panes[writingID]?.values.contains { $0.isWatched } ?? false
    }
}

/// The writing editors open anywhere, by writing: in place in a library
/// window or in a window of their own. A click on a writing's notification
/// brings forward the window already showing it, as it stands, rather than
/// asking for a window — which, since the request also asked for the
/// assistant, matched no window open and opened another at the default size
/// with its writing list showing.
@MainActor
enum OpenWritingEditors {
    private static var editors: [String: [UUID: PaneVisibility]] = [:]

    static func register(_ visibility: PaneVisibility, writingID: String, token: UUID) {
        editors[writingID, default: [:]][token] = visibility
    }

    static func unregister(writingID: String, token: UUID) {
        editors[writingID]?[token] = nil
        if editors[writingID]?.isEmpty == true { editors[writingID] = nil }
    }

    /// The writings an editor is open on.
    ///
    /// The unattended source sweep holds these back: an open editor is a
    /// writing being worked on now, whatever its saved date says. The agent
    /// pane is inside the editor, so a chat or a Terminal turn mid-flight is
    /// covered by the same check.
    static var writingIDs: Set<String> { Set(editors.keys) }

    /// The key window if it shows the writing, else the frontmost that does.
    static func window(showing writingID: String) -> NSWindow? {
        let shown = (editors[writingID]?.values).map { $0.compactMap(\.shownWindow) } ?? []
        guard !shown.isEmpty else { return nil }
        if let key = NSApp.keyWindow, shown.contains(key) { return key }
        return NSApp.orderedWindows.first { shown.contains($0) } ?? shown.first
    }
}

/// Puts a writing editor in `OpenWritingEditors` for as long as it is open.
struct OpenWritingEditorRegistration: ViewModifier {
    let writingID: String
    @State private var visibility = PaneVisibility()
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .reportsVisibility(to: visibility)
            .onAppear { OpenWritingEditors.register(visibility, writingID: writingID, token: token) }
            // A new writing is given its id when first saved.
            .onChange(of: writingID) { old, new in
                OpenWritingEditors.unregister(writingID: old, token: token)
                OpenWritingEditors.register(visibility, writingID: new, token: token)
            }
            .onDisappear { OpenWritingEditors.unregister(writingID: writingID, token: token) }
    }
}

/// The windows that can answer a clicked turn notification: library
/// windows, and writing windows, which can open a writing though they hold
/// no reader chats. One of them opens a writing, so two do not. With no
/// window open at all, a click only brings Lamp forward.
@MainActor
enum AgentTurnRouteWindows {
    fileprivate static let windows = NSHashTable<NSWindow>.weakObjects()

    static func target() -> NSWindow? {
        if let key = NSApp.keyWindow, windows.contains(key) { return key }
        return NSApp.orderedWindows.first { windows.contains($0) && $0.isVisible }
            ?? NSApp.windows.first { windows.contains($0) }
    }
}

/// A window's answer to a clicked turn notification: a reader chat one of
/// its tabs holds is brought forward in it; a writing is opened by one
/// window alone, the key one or the frontmost. Kept out of the library
/// view's body, which is at the type checker's limit.
struct AgentTurnRouteReceiver: ViewModifier {
    /// Shows the chat if this window holds it, and says whether it did.
    /// Nil for a window that holds no reader chats.
    var showReaderChat: ((UUID) -> Bool)?
    @Environment(\.openWindow) private var openWindow
    @State private var host = Host()

    final class Host {
        weak var window: NSWindow?
    }

    private struct Registrar: NSViewRepresentable {
        let host: Host

        final class Probe: NSView {
            var host: Host?
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                host?.window = window
                if let window { AgentTurnRouteWindows.windows.add(window) }
            }
        }

        func makeNSView(context: Context) -> Probe {
            let probe = Probe()
            probe.host = host
            return probe
        }

        func updateNSView(_ probe: Probe, context: Context) {}
    }

    func body(content: Content) -> some View {
        content
            .background {
                Registrar(host: host)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .lampShowAgentTurn)) { note in
                guard let route = note.object as? AgentTurnRoute else { return }
                switch route {
                case .readerChat(let chat):
                    if showReaderChat?(chat) == true {
                        host.window?.makeKeyAndOrderFront(nil)
                    }
                case .writing(let id):
                    guard let window = host.window, window === AgentTurnRouteWindows.target() else { return }
                    if let showing = OpenWritingEditors.window(showing: id) {
                        if showing.isMiniaturized { showing.deminiaturize(nil) }
                        showing.makeKeyAndOrderFront(nil)
                        // Its assistant shown too, where the reply or the
                        // request waiting is.
                        NotificationCenter.default.post(name: .lampShowWritingAssistant, object: id)
                        return
                    }
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

    // On the main actor, both of them: an async delegate method that is not
    // returns on the cooperative pool, and the system then finishes the
    // response there. On the phone that ran UIKit's state-restoration
    // snapshot off the main thread and aborted Lamp on every tap (iOS crash
    // 2026-11-22); the Mac is given no chance to do the same.
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier
            ? [.banner, .sound, .list]
            : []
    }

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == AgentTurnNotifications.categoryIdentifier,
              let route = AgentTurnRoute(userInfo: content.userInfo) else { return }
        NSApp.activate()
        NotificationCenter.default.post(name: .lampShowAgentTurn, object: route)
    }
}
