import AppKit
import LampCore
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
    /// cross-references, footnote markers, web links.
    static let lampLink = NSColor.systemBlue

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = NSColor.systemPurple

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = NSColor(LampColorRole.wordsOfChrist.color)

    /// Behind the words searched for.
    ///
    /// On white, the system yellow at core's `findMatchOpacity`, behind text
    /// that keeps its own colour. On the dark window that same wash composited
    /// to a muddy olive with light text over it, which read as dirt rather
    /// than as a mark. There the match is a solid ground with dark text
    /// (`lampOnFindMatch`), the way a highlighter marks a page — a soft,
    /// low-saturation gold rather than the system yellow, which at full
    /// strength glared off charcoal and made a list of matches look stamped.
    static let lampFindMatch = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.80, green: 0.69, blue: 0.40, alpha: 1)
            : NSColor.systemYellow.withAlphaComponent(LampColorRole.findMatchOpacity)
    }

    /// The words on a find match's ground: their own colour on white, near
    /// black on the dark window's luminous yellow.
    static let lampOnFindMatch = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.09, green: 0.08, blue: 0.05, alpha: 1)
            : NSColor.labelColor
    }

    /// A link set inside dense prose — a definition, a commentary paragraph —
    /// where a run of references in the full system blue took over the
    /// paragraph. Still the link blue (blue takes you somewhere), a step
    /// deeper on white and a step softer on charcoal, so the words between
    /// the references stay the thing being read. About 5.6:1 and 7:1.
    static let lampProseLink = NSColor(name: nil) { appearance in
        appearance.lampIsDark
            ? NSColor(srgbRed: 0.47, green: 0.67, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.38, blue: 0.80, alpha: 1)
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

    /// A link inside dense prose.
    static let lampProseLink = Color(nsColor: .lampProseLink)

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
    /// in label colour on white and near black on the dark window's luminous
    /// yellow (see `lampFindMatch`), and bold. Not bold *accent*, which reads
    /// as a link — the colour is what that rule is about.
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
}
