import SwiftUI

/// The surfaces a conversation is drawn on, defined in one place because they
/// only work as a set.
///
/// Each is ink laid over whatever is beneath it rather than a fixed colour, so
/// a panel inside a bubble inside the conversation deepens by the same step in
/// light and in dark. Named colours cannot do this: `controlBackgroundColor`
/// over `textBackgroundColor` is almost no step at all in light mode, and the
/// code panel — which used to be the conversation's own colour at 60% — came
/// out *lighter* than the bubble holding it.
public enum LampChatSurface {
    /// How much darker (or, in dark mode, lighter) each layer sits than the one
    /// beneath it.
    private static let step = 0.055

    /// What the whole conversation is drawn on.
    public static var conversation: Color { Color(nsColor: .textBackgroundColor) }

    /// The agent's bubble: one step off the conversation.
    public static var agentBubble: Color { .primary.opacity(step) }
    public static var agentBubbleBorder: Color { .primary.opacity(0.10) }

    /// The person's bubble, told apart by hue rather than by weight so it sits
    /// beside the agent's without shouting over the code in it.
    public static var personBubble: Color { .accentColor.opacity(0.16) }
    public static var personBubbleBorder: Color { .accentColor.opacity(0.38) }

    /// A code or diff panel: another step down again, so it reads as inset into
    /// whichever bubble or page holds it.
    public static var codePanel: Color { .primary.opacity(step + 0.01) }
    public static var codePanelBorder: Color { .primary.opacity(0.12) }
    /// The strip above a code panel carrying its language and copy button.
    public static var codePanelHeader: Color { .primary.opacity(0.03) }

    /// A changed line in a diff, tinted enough to scan and not so much that the
    /// code on it stops being legible.
    public static func diffRow(_ kind: LampDiffHighlighter.Line) -> Color {
        switch kind {
        case .added: Color(nsColor: .systemGreen).opacity(0.14)
        case .removed: Color(nsColor: .systemRed).opacity(0.14)
        case .meta, .context: .clear
        }
    }
}
