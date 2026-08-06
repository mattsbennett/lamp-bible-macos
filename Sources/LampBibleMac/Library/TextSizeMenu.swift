#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

enum ProseTypeface: String, CaseIterable, Identifiable {
    case serif
    case sansSerif

    static let readerDefault = ProseTypeface.serif
    static let commentaryDefault = ProseTypeface.sansSerif

    var id: String { rawValue }

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

/// The prose-appearance items themselves, so a panel that already owns a menu can
/// fold them in beside its other controls rather than growing a second `aA` button.
struct TextSizeMenuItems: View {
    let fontSize: Binding<Double>
    let lineSpacing: Binding<Double>
    var typeface: Binding<ProseTypeface>?
    var defaultTypeface: ProseTypeface?
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
