import AppKit
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

// The colours Lamp gives a meaning to, as the Mac app draws them. Which colour
// means what is core's to say (`LampColorRole`, Documentation/ColorRules.md):
// red is the app, blue takes you somewhere in the text, and every other colour
// carries one meaning only. The accent is the AccentColor asset, so macOS can
// hand standard controls the accent the person chose in System Settings.
//
// Ask for the role, not the hue: a view asking for `.lampLink` says why its
// text is blue, and follows the rule if the rule changes.

extension NSColor {
    /// One of core's sRGB values, the same in either appearance.
    convenience init(_ rgb: LampRGB) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// A colour that resolves against the appearance it is drawn in, from
    /// core's values. For the roles that have no system colour to ask for.
    convenience init(_ themed: LampThemedColor) {
        self.init(name: nil) { appearance in
            let rgb = appearance.lampIsDark ? themed.dark : themed.light
            return NSColor(
                srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1
            )
        }
    }

    /// Anything in text that takes you somewhere: verse references,
    /// cross-references, footnote markers, web links. Lamp's own blue rather
    /// than the system's, which took over a paragraph dense with references.
    static let lampLink = NSColor(LampColorRole.link.color)

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = NSColor.systemPurple

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = NSColor(LampColorRole.wordsOfChrist.color)

    /// Behind the words searched for.
    ///
    /// On white, the system yellow at core's `findMatchOpacity`, behind text
    /// that keeps its own colour.
    ///
    /// On the dark window, core's solid deep amber (`findMatchDarkGround`)
    /// under cream words (`lampOnFindMatch`): see ColorRules.md.
    static let lampFindMatch = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(LampColorRole.findMatchDarkGround)
            : NSColor.systemYellow.withAlphaComponent(LampColorRole.findMatchOpacity)
    }

    /// The words on a find match's ground: their own colour on white, core's
    /// cream (`findMatchDarkText`) on the dark window's deep amber.
    static let lampOnFindMatch = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(LampColorRole.findMatchDarkText)
            : NSColor.labelColor
    }

    /// Verse numbers, and the other small apparatus set in among scripture.
    ///
    /// Quieter than the text and louder than `secondaryLabelColor`, which at a
    /// verse number's size faded almost to nothing, most of all on charcoal.
    /// Neutral, never the accent: a red numeral beside red-letter text reads as
    /// part of the words of Christ. About 6.5:1 on white and 7:1 on the dark
    /// reader (8:1 and 8.5:1 since round two, when the panel still found
    /// numbers and small labels faint), so a number can be found by scanning
    /// down the margin.
    static let lampVerseNumber = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.74, green: 0.74, blue: 0.76, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1)
    }

    /// Secondary text that still has to be read rather than glanced past: a
    /// transliteration, a source's name, a minute count, a sense's label.
    /// The same values as verse numbers, for the same reason: the system's
    /// secondary grey is meant for captions beside primary text, and in a
    /// panel where it carries information it read as disabled.
    static let lampSecondaryText = lampVerseNumber

    /// Text that is read at length but is not scripture: commentary, lexicon
    /// definitions. `labelColor` is a hair too black beside scripture's serif
    /// on white and a hair too bright on charcoal for a long dense column;
    /// `secondaryLabelColor` was far too faint for it. About 12:1 in both.
    static let lampProse = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.88, green: 0.88, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
    }

    /// A card's ground: one step off the window, in both appearances, so a
    /// grouped panel separates from the page without a heavy border. The
    /// system's quaternary fills all but vanished on the dark window.
    static let lampCardFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.198, green: 0.198, blue: 0.208, alpha: 1)
            : NSColor(srgbRed: 0.958, green: 0.958, blue: 0.966, alpha: 1)
    }

    /// The hairline around a card, which is what keeps it a card on the dark
    /// window, where one fill against another is only a faint step.
    static let lampCardStroke = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.10)
    }

    /// A popover or menu-like panel laid over the page: opaque, so nothing
    /// behind it shows through, and one step off the page so its edge reads.
    static let lampPopoverFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.245, green: 0.245, blue: 0.255, alpha: 1)
            : NSColor(srgbRed: 0.935, green: 0.935, blue: 0.945, alpha: 1)
    }

    /// The chosen row's tile (`LampListSelection`): with no accent beside
    /// it, a step firmer than a tile that is merely choosable, so it is
    /// found at a glance on white.
    static let lampSelectionFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 1, alpha: 0.13)
            : NSColor(white: 0, alpha: 0.085)
    }

    /// The page under a panel that takes the keyboard (⌘K), dimmed so the
    /// panel's edge reads and the page's words step back, while the page
    /// stays in view. (A material would blur the desktop behind the window,
    /// not the page.)
    static let lampPanelScrim = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 0, alpha: 0.36)
            : NSColor(white: 0, alpha: 0.14)
    }

    /// The shadow under a panel over the page (⌘K): deeper on the dark
    /// window, where a soft one is lost.
    static let lampPanelShadow = NSColor(name: nil) { appearance in
        NSColor(white: 0, alpha: appearance.lampIsDark ? 0.6 : 0.28)
    }

    /// A panel over a dimmed page (⌘K). A popover is one step off the page
    /// it sits on; over a page dimmed beneath it the step goes the other
    /// way, so in light it is the page's own white, and in dark the
    /// popover's lifted grey.
    static let lampRaisedPanelFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.245, green: 0.245, blue: 0.255, alpha: 1)
            : NSColor.white
    }

    /// A tile or row that can be chosen but is not: a chapter in the passage
    /// picker. Visible against an opaque popover in both appearances.
    static let lampTileFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
    }

    /// A choosable tile laid on a popover or card: a step lighter than its
    /// ground, edged by `lampCardStroke`, as a button sits on a panel. Grey
    /// tiles on a grey popover read as heavy, flat blocks.
    static let lampRaisedTile = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 1, alpha: 0.075)
            : NSColor(white: 1, alpha: 0.9)
    }

    /// A side pane beside the page — the study tools — one step off it.
    static let lampInspectorFill = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.180, green: 0.180, blue: 0.188, alpha: 1)
            : NSColor(srgbRed: 0.978, green: 0.978, blue: 0.982, alpha: 1)
    }

    /// Behind a row or tile the pointer is over.
    static let lampRowHover = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.05)
    }
}

extension NSAppearance {
    /// Whether this appearance draws dark, for the colours that take a value
    /// of their own in each.
    var lampIsDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The measurements the app's surfaces share, so a card, a section heading
/// and a tile have one size wherever they turn up.
enum LampMetrics {
    /// A card or grouped panel.
    static let cardRadius: CGFloat = 12
    /// Inside a card.
    static let cardPadding: CGFloat = 16
    /// A tile, chip or selected row inside a card or popover.
    static let tileRadius: CGFloat = 7
    /// Between the cards of a page.
    static let cardSpacing: CGFloat = 20

    /// The rows of a list column beside a page (books, contents, writing):
    /// the name, the line under it, and its smallest notes. One scale, a
    /// step above what these lists began at, which a blind panel found
    /// small against the page beside them in every round.
    static let listTitleSize: CGFloat = 14
    static let listDetailSize: CGFloat = 12.5
    static let listCaptionSize: CGFloat = 11.5
}

extension Color {
    /// Anything in text that takes you somewhere. Set it explicitly, or as the
    /// `tint` of the text drawing it: SwiftUI draws a link in the tint, which
    /// is the accent once the app has one.
    static let lampLink = Color(nsColor: .lampLink)

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = Color(nsColor: .lampOriginalLanguage)

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = Color(nsColor: .lampWordsOfChrist)

    /// Behind the words searched for.
    static let lampFindMatch = Color(nsColor: .lampFindMatch)

    /// The words on a find match's ground.
    static let lampOnFindMatch = Color(nsColor: .lampOnFindMatch)

    /// Behind a row or tile the pointer is over.
    static let lampRowHover = Color(nsColor: .lampRowHover)

    /// A side pane beside the page.
    static let lampInspectorFill = Color(nsColor: .lampInspectorFill)

    /// Verse numbers and scripture's other small apparatus.
    static let lampVerseNumber = Color(nsColor: .lampVerseNumber)

    /// Secondary text that carries information and must stay readable.
    static let lampSecondaryText = Color(nsColor: .lampSecondaryText)

    /// Prose read at length that is not scripture: commentary, definitions.
    static let lampProse = Color(nsColor: .lampProse)

    /// A card's ground, one step off the window.
    static let lampCardFill = Color(nsColor: .lampCardFill)

    /// The hairline around a card.
    static let lampCardStroke = Color(nsColor: .lampCardStroke)

    /// A popover's opaque ground.
    static let lampPopoverFill = Color(nsColor: .lampPopoverFill)
    static let lampPanelScrim = Color(nsColor: .lampPanelScrim)
    static let lampSelectionFill = Color(nsColor: .lampSelectionFill)
    static let lampRaisedPanelFill = Color(nsColor: .lampRaisedPanelFill)
    static let lampPanelShadow = Color(nsColor: .lampPanelShadow)

    /// A choosable tile that is not chosen.
    static let lampTileFill = Color(nsColor: .lampTileFill)

    /// A choosable tile laid on a popover or card.
    static let lampRaisedTile = Color(nsColor: .lampRaisedTile)
}

extension View {
    /// A grouped panel: the card ground, a hairline, and the shared radius.
    /// Used in place of `GroupBox` where the group is a page's content rather
    /// than a form's, since a GroupBox's fill barely shows on the dark window.
    ///
    /// The card is as wide as its content; give the content a flexible frame
    /// first (`.frame(maxWidth: .infinity, alignment: .leading)`) for a card
    /// that fills its column.
    func lampCard(
        padding: CGFloat = LampMetrics.cardPadding,
        radius: CGFloat = LampMetrics.cardRadius
    ) -> some View {
        self
            .padding(padding)
            .background(
                Color.lampCardFill,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.lampCardStroke)
                    .allowsHitTesting(false)
            }
    }

    /// A section heading inside a panel or page: small, semibold, tracked
    /// capitals in the secondary colour, the way the system's own sidebars and
    /// inspectors name a group. One style, so every surface's groups read alike.
    ///
    /// Eleven points and the readable secondary grey rather than the system's
    /// caption size and grey: at ten points in `secondaryLabelColor` the panel
    /// found these labels too faint to scan by, most of all in dark.
    func lampSectionHeading() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(Color.lampSecondaryText)
    }
}

extension Text {
    /// Words searched for, marked as Safari marks a find: on a yellow ground,
    /// in label colour on white and in cream on the dark window's
    /// deep amber (see `lampFindMatch`), and bold. Not bold *accent*, which
    /// reads as a link — the colour is what that rule is about.
    static func lampFindMatch<S: StringProtocol>(_ text: S) -> Text {
        var marked = AttributedString(String(text))
        marked.backgroundColor = .lampFindMatch
        marked.foregroundColor = .lampOnFindMatch
        // Bold as well as yellow, as the iPhone draws it. In small secondary
        // snippet text the ground alone is easy to skim past, and the weight
        // is what the eye catches. ios-56 proposed matching on both; this
        // user agreed. Never the accent — the thing ColorRules.md rules out is
        // accent *colour*, which reads as a link.
        marked.inlinePresentationIntent = .stronglyEmphasized
        return Text(marked)
    }

    /// Text with core's `<mark>` tags drawn as find matches (`lampFindMatch`),
    /// wherever a match is shown: a listed result, the ⌘K palette and
    /// Search's detail passage alike. Rows once marked theirs in semibold
    /// alone, which the owner found too easy to miss as a hit (Nov 2026).
    static func lampMarked(_ source: String) -> Text {
        var remaining = source[...]
        var rendered = Text("")
        while let opening = remaining.range(of: LampSearchSnippet.openingMark),
              let closing = remaining[opening.upperBound...]
                  .range(of: LampSearchSnippet.closingMark) {
            rendered = rendered + Text(String(remaining[..<opening.lowerBound]))
            rendered = rendered + Text.lampFindMatch(remaining[opening.upperBound..<closing.lowerBound])
            remaining = remaining[closing.upperBound...]
        }
        return rendered + Text(String(remaining))
    }
}

/// A choice of one among a few — List or Ring, Visual or Markdown — drawn
/// in the text's own colours: the chosen one raised on a quiet track, as
/// Slide Studio's choice tiles mark theirs.
///
/// Not the system's segmented control, which fills the chosen segment with
/// the accent. Red is for where you are and what you press (ColorRules.md);
/// a mode chosen in a corner of a pane is neither, and a blind panel found
/// the filled segments the loudest thing on screen, louder than the figures
/// they switch between. Use this wherever a segmented picker would go, so
/// every one in the app reads alike.
struct LampSegmentedPicker<ID: Hashable>: View {
    struct Item {
        let id: ID
        let title: String
        var systemImage: String? = nil
    }

    let label: String
    let items: [Item]
    @Binding var selection: ID
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, selection: Binding<ID>, items: [Item]) {
        self.label = label
        self._selection = selection
        self.items = items
    }

    /// The chosen segment, raised off the track: white on light; on dark a
    /// clear step up, since the raised tile's 7.5% vanished on the track.
    private static var chosenFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.lampIsDark
                ? NSColor(white: 1, alpha: 0.2)
                : NSColor(white: 1, alpha: 1)
        })
    }

    private var isSmall: Bool { controlSize == .small || controlSize == .mini }
    private var height: CGFloat { isSmall ? 20 : 24 }
    private var font: Font { .system(size: isSmall ? 11.5 : 13) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                segment(items[index])
            }
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ item: Item) -> some View {
        let isChosen = item.id == selection
        return Button {
            selection = item.id
        } label: {
            Group {
                if let systemImage = item.systemImage {
                    Label(item.title, systemImage: systemImage)
                } else {
                    Text(item.title)
                }
            }
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, isSmall ? 8 : 10)
            .frame(height: height)
            .foregroundStyle(isChosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.lampSecondaryText))
            .background {
                if isChosen {
                    RoundedRectangle(cornerRadius: LampMetrics.tileRadius - 2, style: .continuous)
                        .fill(Self.chosenFill)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .overlay {
                            RoundedRectangle(cornerRadius: LampMetrics.tileRadius - 2, style: .continuous)
                                .strokeBorder(Color.lampCardStroke)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// The chosen row of a content list — a writing, a book, a contents entry,
/// a search result, a ⌘K row — on a rounded grey tile and nothing else, as
/// Raycast marks its rows.
///
/// Not the list's own selection, which fills the row with the accent while
/// the list has focus and turns its words white: red is for where you are
/// and what you press (ColorRules.md), and a whole red row was the loudest
/// thing in the window. A short accent bar beside the tile was tried (Nov
/// 2026); the design panel read tile and bar as two marks for one thing.
struct LampListSelection: View {
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: LampMetrics.tileRadius, style: .continuous)
                    .fill(Color.lampSelectionFill)
            }
        }
        .padding(.horizontal, 6)
    }
}

extension View {
    /// A row of a selectable `List`, drawn with `LampListSelection` in place
    /// of the list's own highlight, and its words kept in their own colours
    /// while chosen. Put it on every row of the list.
    func lampListRow(isSelected: Bool) -> some View {
        self
            .environment(\.backgroundProminence, .standard)
            .listRowBackground(
                ZStack {
                    LampListSelection(isSelected: isSelected)
                    ListHighlightSuppressor()
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            )
    }
}

/// Stops the table a list row sits in from drawing its own selection, so
/// `LampListSelection` is the only mark. SwiftUI's `List` has no setting for
/// this; the row finds its table and asks it, each time it is laid out,
/// since the list may set its style again.
private struct ListHighlightSuppressor: NSViewRepresentable {
    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            quiet()
        }

        override func layout() {
            super.layout()
            quiet()
        }

        func quiet() {
            var view = superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                view = current.superview
            }
        }
    }

    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) { view.quiet() }
}
