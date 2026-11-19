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

/// How long the app's own movements take, where something else has to be
/// timed against one of them.
enum LampMotion {
    /// A column or pane beside a page arriving or leaving.
    static let paneReveal = 0.2
}

extension Animation {
    /// A column or pane beside a page arriving or leaving: a writing list, a
    /// details inspector, an assistant.
    ///
    /// Named rather than written out at each toggle, because the ones that
    /// were written out did not all get written: in the writing workspace the
    /// list in the library pane slid while the same list in the writing
    /// window appeared from nowhere, and showing the details to reveal a
    /// footnote snapped them open where pressing the button for them had not.
    /// A pane that moves in one place and jumps in another reads as a glitch
    /// rather than a style, so the toggles name one animation.
    ///
    /// **Attach it to the value, not only to the change.** These panes are
    /// shown by flags kept in `@AppStorage`, and a defaults change is
    /// published on its own turn of the run loop rather than inside the
    /// `withAnimation` that made it — so the writing list went on appearing
    /// from nowhere with the animation written right there around the
    /// toggle. `.animation(.lampPaneReveal, value:)` on the column that
    /// moves animates it whatever wrote the flag.
    static let lampPaneReveal = Animation.easeInOut(duration: LampMotion.paneReveal)
}

/// A column beside a page, revealed and hidden by its own width.
///
/// `Animatable`, so SwiftUI interpolates the width and lays the row out again
/// on each frame — the page beside it then moves with the column, which is
/// what reads as a sidebar sliding.
///
/// **A column put into and taken out of the hierarchy does not slide**, even
/// inside `withAnimation`. Measured in the app on 2026-11-18: the transaction
/// interpolated 29 times while the page's content moved in exactly one step,
/// because the conditional column animates only its own fade and a
/// `GeometryReader` in the page beside it is handed the final size at once.
/// What the eye saw was the page jumping and the list blinking out — the
/// owner's "the writing list sidebar still doesn't animate".
struct LampPaneWidth: ViewModifier, Animatable {
    var width: Double

    var animatableData: Double {
        get { width }
        set { width = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: max(width, 0))
            .clipped()
    }
}

extension View {
    /// Reveals or hides this column by animating its width, inside an
    /// animated transaction. See `LampPaneWidth`.
    func lampPaneWidth(_ width: Double) -> some View {
        modifier(LampPaneWidth(width: width))
    }
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

/// A disclosure whose whole heading row opens and closes it, not only the
/// small triangle beside it. The system's macOS style answers a click on the
/// triangle alone, a target of a few points against a heading that can run
/// to three lines, as the Septuagint section's does.
///
/// Set on each `DisclosureGroup` itself, never on a window or a container
/// holding a `List`: a sidebar's sections are disclosure groups inside
/// SwiftUI, and set on the window this style drew the main sidebar's rows
/// and icons tiny. The dictionary's entries build the same thing by hand
/// (`DictionaryResultView`): a chevron in a ten-point column, then the
/// heading, the row one button.
struct LampDisclosureStyle: DisclosureGroupStyle {
    /// The chevron's column and the gap after it, which the content is
    /// indented by so it lines up under the heading's words. Less than the
    /// system's inset, which in a column as narrow as the study pane cost a
    /// word a line.
    static let chevronWidth: CGFloat = 10
    static let gap: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: Self.chevronWidth)
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides what is inside" : "Shows what is inside")
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, Self.chevronWidth + Self.gap)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
    ///
    /// A number after Hebrew is held to the English after it first, reading
    /// the text as drawn, without its tags.
    static func lampMarked(_ source: String, mark: LampTextMark? = nil) -> Text {
        let source = LampBidiNumbers.holdingLeftToRight(
            source, ignoring: [LampSearchSnippet.openingMark, LampSearchSnippet.closingMark]
        )
        var remaining = source[...]
        var rendered = Text("")
        while let opening = remaining.range(of: LampSearchSnippet.openingMark),
              let closing = remaining[opening.upperBound...]
                  .range(of: LampSearchSnippet.closingMark) {
            rendered = rendered + Text(String(remaining[..<opening.lowerBound]))
            let words = remaining[opening.upperBound..<closing.lowerBound]
            if let mark {
                // A mark of the reader's own, drawn as it is in the reader.
                var marked = AttributedString(String(words))
                switch mark {
                case .ground(let color):
                    marked.backgroundColor = color
                case .underline(let color, let pattern):
                    marked.swiftUI.underlineStyle = Text.LineStyle(pattern: pattern, color: color)
                }
                rendered = rendered + Text(marked)
            } else {
                rendered = rendered + Text.lampFindMatch(words)
            }
            remaining = remaining[closing.upperBound...]
        }
        return rendered + Text(String(remaining))
    }
}

/// How a reader's own highlight is drawn over the words it marks, where a
/// search shows them: a ground behind them, or a line beneath.
enum LampTextMark {
    case ground(Color)
    case underline(Color, Text.LineStyle.Pattern)
}

/// A control that is words alone, such as "More in Scripture" or "Ask Me
/// Later": drawn in the accent, as the app's controls are.
///
/// Not SwiftUI's `.link` style, which on the Mac draws the system's blue
/// whatever the tint, so every control styled with it came out the colour
/// ColorRules.md keeps for what text takes you to. A link that sits in
/// text and is a button only to open a popover passes its role's colour:
/// `.lampText(.lampLink)` for a reference, `.lampOriginalLanguage` for a
/// Strong's number.
struct LampTextButtonStyle: ButtonStyle {
    var color: Color?

    func makeBody(configuration: Configuration) -> some View {
        Drawn(configuration: configuration, color: color)
    }

    private struct Drawn: View {
        let configuration: ButtonStyleConfiguration
        let color: Color?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == LampTextButtonStyle {
    /// Words alone, in the accent.
    static var lampText: LampTextButtonStyle { LampTextButtonStyle() }
    /// Words alone, in `color`: a link's role, for a link in text.
    static func lampText(_ color: Color) -> LampTextButtonStyle { LampTextButtonStyle(color: color) }
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
    /// Rounded fully, track and chosen segment alike, for a toolbar: the
    /// toolbar sets its items on capsules of glass, and a rounded-square
    /// segment inside one reads as a corner that doesn't belong.
    let isCapsule: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, selection: Binding<ID>, items: [Item], isCapsule: Bool = false) {
        self.label = label
        self._selection = selection
        self.items = items
        self.isCapsule = isCapsule
    }

    /// The track's corners, or the chosen segment's two points inside them,
    /// so the two curves keep the same centre.
    private func shape(inset: CGFloat) -> AnyShape {
        isCapsule
            ? AnyShape(Capsule(style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: LampMetrics.tileRadius - inset, style: .continuous))
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
        .background(Color.primary.opacity(0.07), in: shape(inset: 0))
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
                    shape(inset: 2)
                        .fill(Self.chosenFill)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                        .overlay {
                            shape(inset: 2)
                                .stroke(Color.lampCardStroke, lineWidth: 1)
                                .padding(0.5)
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

// MARK: - Toolbar names that fit

/// Whether a toolbar has room for its buttons' names: set by the view the
/// toolbar belongs to, from the width it is given (`toolbarLabelsFit(from:)`).
extension EnvironmentValues {
    @Entry var toolbarLabelsFit: Bool = true
}

/// A toolbar button's name beside its icon while the window has room for
/// the names, its icon alone when it has not. The overflow menu is left for
/// a window too narrow even for the icons, where a button went before its
/// name did. Sidebar buttons, Undo and Redo, the arrows that step through
/// passages and search fields keep to icons, as the system's do.
///
/// A name shown is the button's own, shortened where it is long; the full
/// name stays as what VoiceOver says.
struct FittingToolbarLabel: ViewModifier {
    @Environment(\.toolbarLabelsFit) private var fits

    func body(content: Content) -> some View {
        if fits {
            content.labelStyle(.titleAndIcon)
        } else {
            content.labelStyle(.iconOnly)
        }
    }
}

/// Sets `toolbarLabelsFit` from this view's own width. Outside the view's
/// `.toolbar`, so its items see it. Written only when the answer changes,
/// not with every point of a resize: in a view as large as the library's,
/// a write per point rebuilt it all the way through a drag.
private struct ToolbarLabelsFitting: ViewModifier {
    let minimumWidth: CGFloat
    @State private var fits = true

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { $0.size.width >= minimumWidth } action: { fits = $0 }
            .environment(\.toolbarLabelsFit, fits)
    }
}

extension View {
    func fittingToolbarLabel() -> some View {
        modifier(FittingToolbarLabel())
    }

    /// Names this view's toolbar buttons while it is at least
    /// `minimumWidth` wide: the width, measured with every name showing,
    /// below which a name would push a button into the overflow menu.
    func toolbarLabelsFit(from minimumWidth: CGFloat) -> some View {
        modifier(ToolbarLabelsFitting(minimumWidth: minimumWidth))
    }
}

/// The widths from which each toolbar's names fit, measured with every name
/// showing (Nov 2026): the view's own width, which beside the window's
/// sections is the window's less the sidebar's 235. Where no width the
/// window allows was too narrow, the figure is a floor, kept so a name that
/// grows still gives way before a button does.
enum ToolbarLabelFit {
    /// The writing editor's window, or Writing with its sections folded:
    /// List, History and Workspace on the left; the surface, Details,
    /// Assistant, the review marks, the deck and Done on the right.
    /// Overflowed below 1,120 — measured while a Save button was still
    /// among them, so with that button gone this is a floor rather than
    /// the width a name gives way at.
    static let writingEditor: CGFloat = 1_120
    /// Writing while reading: List alone.
    static let writingList: CGFloat = 400
    /// The reader: History, the passage, Side by Side, Appearance, Read
    /// Aloud, Chat and Study. With "BSB · Genesis 1" in the passage button,
    /// fit at 1,005 (a 1,240pt window) and overflowed at 985; the button
    /// grows with the book's name, "1 Thessalonians" by some 80, which the
    /// figure leaves room for.
    static let reader: CGFloat = 1_090
    /// Books and the Book Reader window: Group, Add Book and the search
    /// field; Contents and Open in Window in a book. Fit at every width.
    static let books: CGFloat = 600
    /// Reading Plans: New Plan.
    static let readingPlans: CGFloat = 400
    /// Modules: Show, Install, Export, Show in Finder and the filter field.
    /// Fit at every width; the field narrows to its icon first.
    static let modules: CGFloat = 700
    /// Slide Studio: Undo and Redo, Deck, Remote and Play. Fit at the
    /// narrowest the window goes.
    static let slideStudio: CGFloat = 700
}

// MARK: - Filter chips

extension View {
    /// A filter chip: Search's filter capsule, tinted when chosen. Modules'
    /// shelves, Writing's categories and Presentations' kinds are chosen
    /// with it.
    func lampFilterChip(isChosen: Bool, compact: Bool = false) -> some View {
        modifier(LampFilterChip(isChosen: isChosen, compact: compact))
    }
}

/// A filter chip, tinted when chosen. Stronger in dark, where the light
/// tint and outline barely parted a chosen chip from the rest.
private struct LampFilterChip: ViewModifier {
    let isChosen: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .font(compact ? .system(size: 12) : .callout)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 30)
            .background(Capsule().fill(isChosen ? Color.accentColor.opacity(dark ? 0.28 : 0.14) : Color.lampTileFill))
            .overlay(Capsule().strokeBorder(isChosen ? Color.accentColor.opacity(dark ? 0.85 : 0.55) : Color.lampCardStroke))
            .contentShape(Capsule())
    }
}
