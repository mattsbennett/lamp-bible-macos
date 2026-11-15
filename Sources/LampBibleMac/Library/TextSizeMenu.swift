#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI

/// The typeface a prose surface is read in. Its cases are core's, because both
/// apps store the choice under the same `books.typeface` and have to agree on
/// what the stored word means; how it is drawn and what it is called are this
/// app's.
typealias ProseTypeface = LampProseTypeface

extension LampProseTypeface: @retroactive Identifiable {
    static let readerDefault = ProseTypeface.serif
    /// The study panel's, and every popover's that opens on a reference or a
    /// word: serif to begin with, as the reader's is (owner, Nov 2026).
    static let commentaryDefault = ProseTypeface.serif
    /// Quiz cards keep the sans serif the panel had before.
    static let quizDefault = ProseTypeface.sansSerif

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: "Serif"
        case .sansSerif: "Sans Serif"
        }
    }

    var systemImage: String {
        switch self {
        case .serif: "textformat"
        case .sansSerif: "textformat.alt"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sansSerif: .default
        }
    }
}

extension ScripturePreviewContextAmount: Identifiable {
    public var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneVerse: "1 Verse"
        case .threeVerses: "3 Verses"
        case .chapter: "Chapter"
        }
    }
}

/// The study panel's text, as Settings and the panel's own menu set it: its
/// size, typeface and line spacing.
///
/// Every popover that opens on a reference or a word reads it, whatever
/// opened it — the panel, a book, a writing, a quiz or a search — so a verse
/// glanced at reads the same everywhere (owner, Nov 2026, as on the phone).
/// Read here rather than handed in, so no caller can hand in another.
struct StudyPanelText: DynamicProperty {
    @AppStorage("commentary.fontSize") private var storedSize = LampTextScale.commentaryText.defaultValue
    @AppStorage("commentary.typeface") private var storedTypeface = ProseTypeface.commentaryDefault
    @AppStorage("commentary.lineSpacing") private var storedLineSpacing =
        LampTextScale.commentaryLineSpacing.defaultValue

    var fontSize: Double { LampTextScale.commentaryText.clamped(storedSize) }
    var typeface: ProseTypeface { storedTypeface }
    var lineSpacing: Double { LampTextScale.commentaryLineSpacing.clamped(storedLineSpacing) }

    func font(size: Double? = nil, weight: Font.Weight = .regular) -> Font {
        .system(size: size ?? fontSize, weight: weight, design: typeface.design)
    }
}

/// The prose-appearance items themselves, so a panel that already owns a menu can
/// fold them in beside its other controls rather than growing a second `aA` button.
struct TextSizeMenuItems: View {
    let fontSize: Binding<Double>
    let lineSpacing: Binding<Double>
    var typeface: Binding<ProseTypeface>?
    var defaultTypeface: ProseTypeface?
    var previewContextAmount: Binding<ScripturePreviewContextAmount>?
    var fontScale: LampTextScale = .readerText
    var lineSpacingScale: LampTextScale = .readerLineSpacing
    /// Only one text-size menu per window can own ⌘+ / ⌘−; the reader takes them.
    var usesKeyboardShortcuts = false

    var body: some View {
        if let typeface {
            Section("Typeface") {
                Picker("Typeface", selection: typeface) {
                    ForEach(ProseTypeface.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }

        if let previewContextAmount {
            Menu("Preview Context", systemImage: "rectangle.expand.vertical") {
                Picker("Preview Context", selection: previewContextAmount) {
                    ForEach(ScripturePreviewContextAmount.allCases) { amount in
                        Text(amount.title).tag(amount)
                    }
                }
                .labelsHidden()
            }
        }

        Section("Text Size") {
            Text("\(measurement(fontSize.wrappedValue)) pt")
            Button("Larger", systemImage: "textformat.size.larger") {
                stepFontSize(1)
            }
            .disabled(!fontScale.canIncrease(fontSize.wrappedValue))
            .modifier(TextSizeShortcut(key: "+", enabled: usesKeyboardShortcuts))

            Button("Smaller", systemImage: "textformat.size.smaller") {
                stepFontSize(-1)
            }
            .disabled(!fontScale.canDecrease(fontSize.wrappedValue))
            .modifier(TextSizeShortcut(key: "-", enabled: usesKeyboardShortcuts))
        }

        Section("Line Spacing") {
            Text("\(measurement(lineSpacing.wrappedValue)) pt")
            Button("Looser", systemImage: "arrow.up.and.down.text.horizontal") {
                stepLineSpacing(1)
            }
            .disabled(!lineSpacingScale.canIncrease(lineSpacing.wrappedValue))

            Button("Tighter", systemImage: "arrow.down.and.line.horizontal.and.arrow.up") {
                stepLineSpacing(-1)
            }
            .disabled(!lineSpacingScale.canDecrease(lineSpacing.wrappedValue))
        }

        Button("Reset Text Appearance", systemImage: "arrow.uturn.backward") {
            fontSize.wrappedValue = fontScale.defaultValue
            lineSpacing.wrappedValue = lineSpacingScale.defaultValue
            if let typeface, let defaultTypeface {
                typeface.wrappedValue = defaultTypeface
            }
        }
        .disabled(isAtDefaults)
    }

    private var isAtDefaults: Bool {
        let typefaceIsAtDefault: Bool
        if let typeface, let defaultTypeface {
            typefaceIsAtDefault = typeface.wrappedValue == defaultTypeface
        } else {
            typefaceIsAtDefault = true
        }
        return fontSize.wrappedValue == fontScale.defaultValue
            && lineSpacing.wrappedValue == lineSpacingScale.defaultValue
            && typefaceIsAtDefault
    }

    private func stepFontSize(_ steps: Int) {
        fontSize.wrappedValue = fontScale.stepped(fontSize.wrappedValue, by: steps)
    }

    private func stepLineSpacing(_ steps: Int) {
        lineSpacing.wrappedValue = lineSpacingScale.stepped(lineSpacing.wrappedValue, by: steps)
    }

    private func measurement(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// The standalone `aA` control, for prose that has no appearance menu of its own.
/// Each place that shows prose keeps its own stored typography — scripture and
/// commentary are read at different distances and in columns of different widths
/// — so this takes its bindings and its bounds rather than reaching for a shared
/// default.
struct TextSizeMenu: View {
    let fontSize: Binding<Double>
    let lineSpacing: Binding<Double>
    var typeface: Binding<ProseTypeface>?
    var defaultTypeface: ProseTypeface?
    var previewContextAmount: Binding<ScripturePreviewContextAmount>?
    var fontScale: LampTextScale = .readerText
    var lineSpacingScale: LampTextScale = .readerLineSpacing
    var help: String = "Choose the typeface, text size, and line spacing"
    var usesKeyboardShortcuts = false

    var body: some View {
        Menu("Text Appearance", systemImage: "textformat.size") {
            TextSizeMenuItems(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                typeface: typeface,
                defaultTypeface: defaultTypeface,
                previewContextAmount: previewContextAmount,
                fontScale: fontScale,
                lineSpacingScale: lineSpacingScale,
                usesKeyboardShortcuts: usesKeyboardShortcuts
            )
        }
        .help(help)
    }
}

/// `keyboardShortcut` has no "no shortcut" argument, and a second menu claiming
/// ⌘+ would leave both bindings ambiguous.
private struct TextSizeShortcut: ViewModifier {
    let key: KeyEquivalent
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
