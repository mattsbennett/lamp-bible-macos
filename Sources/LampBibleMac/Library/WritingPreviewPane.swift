import LampCore
import LampModuleKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// The rendered view of a draft, shown either beside the writing surface or alone.
///
/// Modelled on Obsidian's reading view: a quiet header identifying the pane and
/// the controls that belong to it, then the document as a reader will meet it.
/// The pane owns its own typography — proofreading prose is not the same activity
/// as writing it, and the sizes that suit each differ.
struct WritingPreviewPane: View {
    let title: String
    let subtitle: String
    let summary: String
    let keyScriptures: [LampScriptureLink]
    let markdown: String
    let footnotes: String
    let libraryRootURL: URL
    var devotionalID: String? = nil
    var mediaReferences: [LampDevotionalMediaReference] = []
    @Binding var placement: WritingPreviewPlacement
    /// How far through the writing surface the author has scrolled, when the two
    /// panes are side by side. Nil leaves the preview scrolling independently.
    var followedScrollFraction: Double?

    @AppStorage("writing.preview.fontSize")
    private var fontSize = LampTextScale.writingPreviewText.defaultValue
    @AppStorage("writing.preview.lineSpacing")
    private var lineSpacing = LampTextScale.writingPreviewLineSpacing.defaultValue
    @AppStorage("writing.preview.typeface")
    private var typeface = ProseTypeface.readerDefault
    @AppStorage("writing.preview.followsEditorScrolling")
    private var followsEditorScrolling = true

    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var geometry = PreviewScrollGeometry()

    private var canFollowScrolling: Bool {
        placement == .split && followedScrollFraction != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            documentScrollView
        }
        .background(.background.secondary)
        .onChange(of: followedScrollFraction) { _, fraction in
            guard followsEditorScrolling, canFollowScrolling, let fraction else { return }
            scrollPosition.scrollTo(y: ProportionalScrollSync.offset(
                fraction: fraction,
                contentHeight: geometry.contentHeight,
                viewportHeight: geometry.viewportHeight
            ))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Preview", systemImage: "book")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 8)

            if placement == .split {
                Toggle(isOn: $followsEditorScrolling) {
                    Label(
                        "Follow Editor Scrolling",
                        systemImage: followsEditorScrolling ? "link.circle.fill" : "link.circle"
                    )
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(followsEditorScrolling
                    ? "Stop the preview following the editor"
                    : "Keep the preview on the paragraph being written")
            }

            TextSizeMenu(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                typeface: $typeface,
                defaultTypeface: ProseTypeface.readerDefault,
                fontScale: .writingPreviewText,
                lineSpacingScale: .writingPreviewLineSpacing,
                help: "Adjust the preview typeface, text size, and line spacing"
            )
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .frame(width: 24)

            Button {
                placement = placement.cycledPlacement()
            } label: {
                Label(
                    placement == .full ? "Show Beside Editor" : "Fill the Window",
                    systemImage: placement == .full
                        ? "rectangle.split.2x1"
                        : "rectangle.expand.vertical"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(placement == .full
                ? "Show the preview beside the editor"
                : "Let the preview fill the window")

            Button {
                placement = .hidden
            } label: {
                Label("Close Preview", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close the preview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Document

    private var documentScrollView: some View {
        ScrollView {
            document
                // A measured line length rather than the full pane width. Prose set
                // across a wide window is markedly harder to proofread, and the
                // preview exists to be proofread.
                .frame(maxWidth: 680, alignment: .leading)
                .padding(28)
                // Beside the editor the column stays left, against the divider it
                // shares an edge with. Filling the window there is nothing to align
                // to, so the measured column centres rather than stranding itself
                // against one edge of an empty pane.
                .frame(
                    maxWidth: .infinity,
                    alignment: placement == .full ? .top : .topLeading
                )
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: PreviewScrollGeometry.self) { proxy in
            PreviewScrollGeometry(
                contentHeight: proxy.contentSize.height,
                viewportHeight: proxy.containerSize.height
            )
        } action: { _, updated in
            geometry = updated
        }
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 18) {
            if hasFrontMatter {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: fontSize * 1.9, weight: .bold, design: typeface.design))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: fontSize * 1.2, design: typeface.design))
                            .foregroundStyle(.secondary)
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: fontSize, design: typeface.design))
                            .lineSpacing(lineSpacing)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }

            if !keyScriptures.isEmpty {
                keyScriptureRow
            }

            if hasFrontMatter || !keyScriptures.isEmpty {
                Divider()
            }

            DevotionalContentView(
                markdown: markdown,
                libraryRootURL: libraryRootURL,
                devotionalID: devotionalID,
                mediaReferences: mediaReferences,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                typeface: typeface,
                emptyState: AnyView(emptyState),
                // Only when the pane is actually showing the title above; with no
                // front matter the document's own heading is all there is.
                titleShownAbove: hasFrontMatter ? title : nil
            )

            if !footnotes.isEmpty {
                Divider()
                DevotionalContentView(
                    markdown: footnotes,
                    libraryRootURL: libraryRootURL,
                    devotionalID: devotionalID,
                    mediaReferences: mediaReferences,
                    fontSize: max(fontSize - 2, 11),
                    lineSpacing: lineSpacing,
                    typeface: typeface
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var keyScriptureRow: some View {
        // Wrapping rather than a fixed row: a devotional can carry more key
        // scripture than a narrow split pane has room for on one line.
        WrappingRow(spacing: 8) {
            ForEach(keyScriptures) { scripture in
                Text(scripture.displayDescription)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var hasFrontMatter: Bool {
        !title.isEmpty || !subtitle.isEmpty || !summary.isEmpty
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to Preview Yet", systemImage: "text.alignleft")
        } description: {
            Text("Write in the editor and the rendered devotional appears here.")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }
}

private struct PreviewScrollGeometry: Equatable {
    var contentHeight: Double = 0
    var viewportHeight: Double = 0
}
