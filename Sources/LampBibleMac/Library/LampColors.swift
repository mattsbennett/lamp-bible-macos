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
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? themed.dark : themed.light
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
    static let lampFindMatch = NSColor.systemYellow
        .withAlphaComponent(LampColorRole.findMatchOpacity)
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
}

extension Text {
    /// Words searched for, marked as Safari marks a find: on a yellow ground,
    /// in the text's own colour, and bold. Not bold *accent*, which reads as
    /// a link — the colour is what that rule is about.
    static func lampFindMatch<S: StringProtocol>(_ text: S) -> Text {
        var marked = AttributedString(String(text))
        marked.backgroundColor = .lampFindMatch
        // Bold as well as yellow, as the iPhone draws it. In small secondary
        // snippet text the ground alone is easy to skim past, and the weight
        // is what the eye catches. ios-56 proposed matching on both; this
        // user agreed. Still the text's own colour — the thing ColorRules.md
        // rules out is accent *colour*, which reads as a link.
        marked.inlinePresentationIntent = .stronglyEmphasized
        return Text(marked)
    }
}
