import AppKit
import AVFoundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

struct DevotionalContentView: View {
    let markdown: String
    let libraryRootURL: URL
    var fontSize: Double = 17

    @State private var presentedImage: PresentedDevotionalImage?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let markdown):
                    markdownText(markdown)
                        .font(.system(size: fontSize, design: .serif))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                case .image(let caption, let url):
                    if let image = NSImage(contentsOf: resolvedURL(url)) {
                        Button {
                            presentedImage = PresentedDevotionalImage(image: image, caption: caption)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 720, maxHeight: 520)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                if !caption.isEmpty {
                                    Text(caption).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        unavailableMedia(caption.isEmpty ? "Image" : caption, systemImage: "photo")
                    }
                case .audio(let label, let url):
                    DevotionalAudioView(label: label, url: resolvedURL(url))
                }
            }
        }
        .sheet(item: $presentedImage) { item in
            VStack(spacing: 14) {
                Image(nsImage: item.image)
                    .resizable()
                    .scaledToFit()
                if !item.caption.isEmpty {
                    Text(item.caption).font(.headline)
                }
            }
            .padding(24)
            .frame(minWidth: 780, minHeight: 600)
        }
    }

    @ViewBuilder
    private func markdownText(_ value: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed)
        } else {
            Text(value)
        }
    }

    private func unavailableMedia(_ label: String, systemImage: String) -> some View {
        Label("\(label) is unavailable on this Mac", systemImage: systemImage)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
    }

    private func resolvedURL(_ url: URL) -> URL {
        guard url.scheme == "lamp-media" else { return url }
        let devotionalID = url.host ?? ""
        return libraryRootURL
            .appendingPathComponent("Media/Devotionals", isDirectory: true)
            .appendingPathComponent(devotionalID, isDirectory: true)
            .appendingPathComponent(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private var blocks: [DevotionalMarkdownBlock] {
        DevotionalMarkdownParser.parse(markdown)
    }
}

private struct DevotionalAudioView: View {
    let label: String
    let url: URL
    @StateObject private var player = DevotionalAudioPlayer()

    var body: some View {
        HStack(spacing: 12) {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle(url: url)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.isEmpty ? "Audio" : label).font(.headline)
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { player.stop() }
    }
}

@MainActor
private final class DevotionalAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVPlayer?

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil { player = AVPlayer(url: url) }
            player?.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
    }
}

private struct PresentedDevotionalImage: Identifiable {
    let id = UUID()
    let image: NSImage
    let caption: String
}
