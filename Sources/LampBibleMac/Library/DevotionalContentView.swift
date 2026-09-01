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
    var lineSpacing: Double = 6
    var typeface: ProseTypeface = .serif
    /// Shown in place of the renderer when there is nothing written yet, so an
    /// empty preview explains itself instead of looking like a failure.
    var emptyState: AnyView?
    /// The title the host already displays above this content. A first heading
    /// that only restates it is dropped rather than printed twice.
    var titleShownAbove: String?

    @State private var presentedImage: PresentedDevotionalImage?
    @State private var renderedContent: RenderedDevotionalContent?

    private var hasContent: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Drops an opening heading that only repeats the title already on screen.
    /// Only the very first block qualifies — a later section that happens to
    /// share the title's wording is part of the document.
    private func visibleBlocks(of content: RenderedDevotionalContent) -> [RenderedDevotionalBlock] {
        guard let titleShownAbove,
              case .prose(.heading(_, let heading))? = content.blocks.first,
              DevotionalHeadingMatch.restatesTitle(heading.plain, title: titleShownAbove)
        else { return content.blocks }
        return Array(content.blocks.dropFirst())
    }

    var body: some View {
        Group {
            if let emptyState, !hasContent {
                emptyState
            } else if let renderedContent, renderedContent.source == markdown {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(visibleBlocks(of: renderedContent).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .prose(let prose):
                            proseBlock(prose)
                                .textSelection(.enabled)
                        case .image(let caption, let url):
                            DevotionalImageBlockView(
                                caption: caption,
                                url: resolvedURL(url),
                                openImage: { image in
                                    presentedImage = PresentedDevotionalImage(
                                        image: image,
                                        caption: caption
                                    )
                                }
                            )
                        case .audio(let label, let url):
                            DevotionalAudioView(label: label, url: resolvedURL(url))
                        }
                    }
                }
            } else {
                ProgressView("Rendering preview…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: markdown) {
            let source = markdown
            if renderedContent?.source != source {
                renderedContent = nil
            }
            let blocks = await DevotionalContentRenderer.shared.render(source)
            guard !Task.isCancelled, source == markdown else { return }
            renderedContent = RenderedDevotionalContent(source: source, blocks: blocks)
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
    private func proseBlock(_ block: RenderedProseBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderedText(text)
                .font(.system(
                    size: headingSize(for: level),
                    weight: level <= 2 ? .bold : .semibold,
                    design: typeface.design
                ))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            renderedText(text)
                .font(.system(size: fontSize, design: typeface.design))
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let paragraphs):
            HStack(alignment: .top, spacing: 12) {
                // The bar is the whole visual signal a quote gets, so it is drawn
                // rather than left to an indent a reader could mistake for a list.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        renderedText(paragraph)
                            .font(.system(size: fontSize, design: typeface.design).italic())
                            .lineSpacing(lineSpacing)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .bulletList(let items):
            listBlock(items) { _ in "•" }
        case .numberedList(let items):
            listBlock(items) { "\($0 + 1)." }
        case .rule:
            Divider()
        }
    }

    private func listBlock(
        _ items: [RenderedProseItem],
        marker: @escaping (Int) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(marker(index))
                        .font(.system(size: fontSize, design: typeface.design))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    renderedText(item)
                        .font(.system(size: fontSize, design: typeface.design))
                        .lineSpacing(lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Headings step down toward the body size rather than using fixed system
    /// sizes, so the whole document scales together with the preview's text size.
    private func headingSize(for level: Int) -> Double {
        switch level {
        case 1: fontSize * 1.55
        case 2: fontSize * 1.3
        case 3: fontSize * 1.15
        default: fontSize * 1.05
        }
    }

    @ViewBuilder
    private func renderedText(_ item: RenderedProseItem) -> some View {
        if let attributed = item.attributed {
            Text(attributed)
        } else {
            Text(item.plain)
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

}

private struct RenderedDevotionalContent {
    let source: String
    let blocks: [RenderedDevotionalBlock]
}

private enum RenderedDevotionalBlock: Sendable {
    case prose(RenderedProseBlock)
    case image(caption: String, url: URL)
    case audio(label: String, url: URL)
}

/// A run of prose with its inline markdown already resolved. Parsing happens off
/// the main actor, so the attributed value is built once per edit rather than on
/// every layout pass.
private struct RenderedProseItem: Sendable {
    let plain: String
    let attributed: AttributedString?

    init(_ source: String) {
        plain = source
        attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

private enum RenderedProseBlock: Sendable {
    case heading(level: Int, text: RenderedProseItem)
    case paragraph(RenderedProseItem)
    case quote([RenderedProseItem])
    case bulletList([RenderedProseItem])
    case numberedList([RenderedProseItem])
    case rule

    init(_ block: DevotionalProseBlock) {
        switch block {
        case .heading(let level, let text):
            self = .heading(level: level, text: RenderedProseItem(text))
        case .paragraph(let text):
            self = .paragraph(RenderedProseItem(text))
        case .quote(let paragraphs):
            self = .quote(paragraphs.map(RenderedProseItem.init))
        case .bulletList(let items):
            self = .bulletList(items.map(RenderedProseItem.init))
        case .numberedList(let items):
            self = .numberedList(items.map(RenderedProseItem.init))
        case .rule:
            self = .rule
        }
    }
}

private actor DevotionalContentRenderer {
    static let shared = DevotionalContentRenderer()

    private let cacheLimit = 24
    private var cache: [String: [RenderedDevotionalBlock]] = [:]
    private var cacheOrder: [String] = []

    func render(_ markdown: String) -> [RenderedDevotionalBlock] {
        if let cached = cache[markdown] {
            return cached
        }
        let rendered = DevotionalMarkdownParser.parse(markdown).flatMap {
            block -> [RenderedDevotionalBlock] in
            switch block {
            case .text(let value):
                // One `.text` run holds every consecutive prose line, so it has to
                // be split back into headings, quotes, lists and paragraphs before
                // any of them can be styled.
                return DevotionalProseParser.parse(value).map {
                    .prose(RenderedProseBlock($0))
                }
            case .image(let caption, let url):
                return [.image(caption: caption, url: url)]
            case .audio(let label, let url):
                return [.audio(label: label, url: url)]
            }
        }
        cache[markdown] = rendered
        cacheOrder.append(markdown)
        if cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return rendered
    }
}

private struct DevotionalImageBlockView: View {
    let caption: String
    let url: URL
    let openImage: (NSImage) -> Void

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Button { openImage(image) } label: {
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
            } else if didFail {
                Label(
                    "\(caption.isEmpty ? "Image" : caption) is unavailable on this Mac",
                    systemImage: "photo"
                )
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
            } else {
                ProgressView(caption.isEmpty ? "Loading image…" : "Loading \(caption)…")
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            image = nil
            didFail = false
            let data = try? await Task.detached(priority: .utility) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
            didFail = image == nil
        }
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
