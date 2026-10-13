import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import LampBibleMacSupport

/// Renders the conversation's surfaces off-screen so the layering can be seen
/// rather than reasoned about. Each layer must read as sitting inside the one
/// beneath it, in light and in dark.
@MainActor
struct ChatSurfaceProbeTests {
    private func conversation(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The person: told apart by hue.
            HStack {
                Spacer()
                Text("Can you show me the change?")
                    .padding(12)
                    .background(LampChatSurface.personBubble, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(LampChatSurface.personBubbleBorder)
                    )
            }

            // The agent: a bubble holding an inset code panel.
            VStack(alignment: .leading, spacing: 10) {
                Text("I renamed the helper:")
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("diff").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Copy").font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(LampChatSurface.codePanelHeader)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        row(" let total = items.count", .context)
                        row("-let old = compute()", .removed)
                        row("+let new = compute()", .added)
                    }
                    .padding(.vertical, 8)
                }
                .background(LampChatSurface.codePanel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(LampChatSurface.codePanelBorder))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LampChatSurface.agentBubble, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(LampChatSurface.agentBubbleBorder))
        }
        .padding(16)
        .frame(width: 520)
        .background(LampChatSurface.conversation)
        .environment(\.colorScheme, scheme)
    }

    private func row(_ text: String, _ kind: LampDiffHighlighter.Line) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(kind == .added ? Color(nsColor: .systemGreen)
                : kind == .removed ? Color(nsColor: .systemRed) : Color.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LampChatSurface.diffRow(kind))
    }

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func drawsTheConversationSurfaces(scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: conversation(scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let name = scheme == .light ? "light" : "dark"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lamp-chat-surfaces-\(name).png")
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try #require(representation.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("PROBE wrote \(url.path)")
        #expect(image.width > 0)
    }
}
