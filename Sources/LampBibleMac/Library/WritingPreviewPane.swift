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
    /// The note a marker was just clicked for, marked while the writer's eye
    /// arrives at it.
    @State private var highlightedFootnote: Int?

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
        // A marker in the prose is a link to its note. Every other link is one
        // the writer put there and opens as it would anywhere else.
        .environment(\.openURL, OpenURLAction { url in
            guard let number = LampDevotionalFootnotes.markerNumber(in: url) else {
                return .systemAction
            }
            show(footnote: number)
            return .handled
        })
    }

    /// Takes the writer to the note a marker refers to, and marks it for a
    /// moment: arriving in the middle of thirty-five numbered lines, the scroll
    /// by itself does not say which of them was asked for.
    private func show(footnote number: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollPosition.scrollTo(id: WritingFootnoteAnchor(number: number), anchor: .center)
            highlightedFootnote = number
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1_600))
            guard highlightedFootnote == number else { return }
            withAnimation(.easeOut(duration: 0.4)) { highlightedFootnote = nil }
        }
    }

    private var document: some View {
        let footnoting = numberedFootnotes
        return VStack(alignment: .leading, spacing: 18) {
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
                markdown: LampDevotionalFootnotes.displayContent(
                    footnoting, linkingMarkers: true
                ),
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

            if !footnoting.footnotes.isEmpty || !footnoting.preamble.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    // Anything the writer put above the definitions is theirs
                    // and is shown as the writing it is.
                    if !footnoting.preamble.isEmpty {
                        DevotionalContentView(
                            markdown: footnoting.preamble,
                            libraryRootURL: libraryRootURL,
                            devotionalID: devotionalID,
                            mediaReferences: mediaReferences,
                            fontSize: max(fontSize - 2, 11),
                            lineSpacing: lineSpacing,
                            typeface: typeface
                        )
                    }
                    if !footnoting.footnotes.isEmpty {
                        WritingFootnoteList(
                            footnotes: footnoting.footnotes,
                            fontSize: max(fontSize - 2, 11),
                            lineSpacing: lineSpacing,
                            typeface: typeface,
                            highlighted: highlightedFootnote
                        )
                    }
                }
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

    /// The writing's footnotes numbered by the order of their first reference,
    /// so the labels in the source can be anything and a reader still sees
    /// 1, 2, 3. The source is never rewritten: an agent may be editing it.
    ///
    /// Both halves of the pane read from this one numbering, or a marker and
    /// its note could disagree. Writing with no footnotes costs a scan for the
    /// two characters that open a marker and nothing more.
    private var numberedFootnotes: LampDevotionalFootnotes.Numbered {
        LampDevotionalFootnotes.numbered(content: markdown, footnotes: footnotes)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to Preview Yet", systemImage: "text.alignleft")
        } description: {
            Text("Write in the editor and your rendered writing appears here.")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }
}

private struct PreviewScrollGeometry: Equatable {
    var contentHeight: Double = 0
    var viewportHeight: Double = 0
}

/// What a marker's link scrolls to.
///
/// A type of its own, so a footnote's number cannot collide with the identity
/// of anything else in the document — the blocks above it are identified by
/// their position, and footnote 3 is not block 3.
private struct WritingFootnoteAnchor: Hashable {
    let number: Int
}

/// The notes beneath the writing, each on a row of its own.
///
/// Drawn here rather than handed to the renderer as a Markdown list, which is
/// how they used to be shown: a list is one block, and a line inside it has no
/// identity for a marker to scroll to.
private struct WritingFootnoteList: View {
    let footnotes: [LampDevotionalFootnotes.Footnote]
    let fontSize: Double
    let lineSpacing: Double
    let typeface: ProseTypeface
    /// The note just asked for, tinted until the writer has found it.
    let highlighted: Int?

    /// The notes with their inline Markdown resolved. Parsed off the main actor
    /// and only when the notes themselves change: the preview is rebuilt as the
    /// prose is typed, and a talk can carry thirty-five notes.
    @State private var rows: [Row] = []

    struct Row: Identifiable, Sendable {
        let id: Int
        let text: AttributedString

        init(_ footnote: LampDevotionalFootnotes.Footnote) {
            id = footnote.number
            let source = LampDevotionalFootnotes.displayText(of: footnote)
            text = (try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(row.id).")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(highlighted == row.id ? 0.16 : 0))
                )
                .id(WritingFootnoteAnchor(number: row.id))
            }
        }
        .font(.system(size: fontSize, design: typeface.design))
        .lineSpacing(lineSpacing)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: footnotes) {
            let notes = footnotes
            let parsed = await Task.detached(priority: .userInitiated) {
                notes.map(Row.init)
            }.value
            guard !Task.isCancelled else { return }
            rows = parsed
        }
    }
}
