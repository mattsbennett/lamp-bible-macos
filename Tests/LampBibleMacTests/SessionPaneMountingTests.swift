import Foundation
import Testing

/// Chat and Terminal share one pane. Whichever is not showing must still be
/// *mounted* while its session is live, because SwiftUI tearing the view down
/// ends what is running in it: the terminal view kills the provider process,
/// and the chat view stops the reply it is waiting on.
///
/// The chat half of that was missing, so switching to Terminal to see how a
/// long reply was getting on was what ended the reply — reported afterwards as
/// "Claude exited with status 143", which is simply what a terminated CLI
/// exits with.
///
/// This reads the source because the condition is a SwiftUI view-builder
/// branch with no seam to test through; the rule it protects is worth more
/// than the brittleness of checking it this way.
struct SessionPaneMountingTests {
    private var workspaceViewSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LampBibleMac/Library/DevotionalAgentWorkspaceView.swift"
                )
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func sessionPane(in source: String) throws -> String {
        let start = try #require(source.range(of: "private var sessionPane: some View {"))
        let end = try #require(
            source.range(of: "private var terminalPane", range: start.upperBound..<source.endIndex)
        )
        return String(source[start.upperBound..<end.lowerBound])
    }

    @Test func theChatPaneStaysMountedWhileItIsWaitingOnAReply() throws {
        let pane = try sessionPane(in: try workspaceViewSource)
        let condition = try #require(
            pane.range(of: "if sessionMode == .native")
                .map { pane[$0.lowerBound...].prefix(while: { $0 != "\n" }) }
        )
        #expect(
            condition.contains("chatIsReplying"),
            """
            The chat view is mounted only when Chat is the selected mode, so \
            switching to Terminal unmounts it and stops the reply in flight. \
            Condition was: \(condition)
            """
        )
    }

    @Test func theTerminalPaneStaysMountedWhileItsSessionIsLive() throws {
        let pane = try sessionPane(in: try workspaceViewSource)
        let condition = try #require(
            pane.range(of: "if activeProvider != nil")
                .map { pane[$0.lowerBound...].prefix(while: { $0 != "\n" }) }
        )
        #expect(condition.contains("sessionMode == .terminal"))
    }

    /// Both panes are in one `ZStack`, so the hidden one has to be taken out
    /// of the way as well as made invisible — otherwise it swallows the
    /// clicks and keystrokes meant for the one on show.
    @Test func theHiddenPaneDoesNotTakeInput() throws {
        let pane = try sessionPane(in: try workspaceViewSource)
        #expect(pane.contains(".allowsHitTesting(sessionMode == .terminal)"))
        #expect(pane.contains(".allowsHitTesting(sessionMode == .native)"))
        #expect(pane.contains(".accessibilityHidden(sessionMode != .terminal)"))
        #expect(pane.contains(".accessibilityHidden(sessionMode != .native)"))
    }
}
