import Foundation

/// A keystroke aimed at the embedded terminal, as the modifiers that were held
/// down and the key that was pressed.
///
/// Modelled rather than taken as an `NSEvent` so the mapping below can be read
/// and tested without synthesising events.
public struct LampTerminalKeyChord: Hashable, Sendable {
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        keyCode: UInt16,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// The key codes macOS reports for the keys this map cares about.
    public enum Key {
        public static let returnKey: UInt16 = 36
        public static let keypadEnter: UInt16 = 76
        public static let delete: UInt16 = 51
        public static let forwardDelete: UInt16 = 117
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let home: UInt16 = 115
        public static let end: UInt16 = 119
    }
}

/// What Lamp sends for the keystrokes the terminal view gets wrong or ignores.
///
/// SwiftTerm handles most of a Mac keyboard, and everything it handles is left
/// to it. These are the ones it does not, measured by driving its `keyDown`
/// and recording the bytes that came out:
///
/// | Keystroke | SwiftTerm sent | Should send |
/// | --- | --- | --- |
/// | ⌘⌫ | nothing | `15` — kill to the start of the line |
/// | ⌘⌦ | plain forward delete | `0B` — kill to the end of the line |
/// | ⌘← / ⌘→ | `1B 62` / `1B 66`, a *word* | `01` / `05`, the line's ends |
/// | ⌥⌦ | `1B EF 9C A8`, the raw key scalar | `1B 64` — kill the word ahead |
/// | Home / End | nothing | `1B 5B 48` / `1B 5B 46` |
///
/// ⌥⌫ is already right (`1B 7F`) and is not listed: a CLI that ignores it is
/// ignoring the sequence every terminal sends.
public enum LampTerminalKeyMap {
    /// The bytes to send for `chord`, or nil to leave it to the terminal view.
    ///
    /// Modifiers must match exactly. ⇧⌘← selects in most CLIs and ⌃⌘← belongs
    /// to Spaces, so a chord carrying anything extra is somebody else's.
    public static func bytes(for chord: LampTerminalKeyChord) -> [UInt8]? {
        switch (chord.keyCode, chord.command, chord.option, chord.control, chord.shift) {
        // ESC then CR: meta-Return, as a configured terminal sends it, so a
        // CLI's prompt takes a newline instead of submitting what is typed.
        case (LampTerminalKeyChord.Key.returnKey, false, false, false, true),
             (LampTerminalKeyChord.Key.keypadEnter, false, false, false, true):
            return [0x1B, 0x0D]

        // Readline's unix-line-discard and kill-line.
        case (LampTerminalKeyChord.Key.delete, true, false, false, false):
            return [0x15]
        case (LampTerminalKeyChord.Key.forwardDelete, true, false, false, false):
            return [0x0B]

        // A Mac's ⌘← and ⌘→ mean the ends of the line, not the next word over.
        case (LampTerminalKeyChord.Key.leftArrow, true, false, false, false):
            return [0x01]
        case (LampTerminalKeyChord.Key.rightArrow, true, false, false, false):
            return [0x05]

        // ESC d, the forward half of the ⌥⌫ that already works.
        case (LampTerminalKeyChord.Key.forwardDelete, false, true, false, false):
            return [0x1B, 0x64]

        case (LampTerminalKeyChord.Key.home, false, false, false, false):
            return [0x1B, 0x5B, 0x48]
        case (LampTerminalKeyChord.Key.end, false, false, false, false):
            return [0x1B, 0x5B, 0x46]

        default:
            return nil
        }
    }
}

/// Stepping a selection through an ordered list, for the arrow keys in the
/// slide navigator.
public enum LampSlideSelection {
    /// The slide an arrow key should land on, or nil when it should stay put.
    ///
    /// The ends do not wrap: holding an arrow down to reach the end of a deck
    /// should stop there rather than reappearing at the other end. With nothing
    /// selected the first slide is the starting point, so one press selects
    /// something rather than nothing.
    public static func stepping(
        from selected: String?,
        by offset: Int,
        through ids: [String]
    ) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let current = ids.firstIndex(of: selected) else {
            return ids.first
        }
        let destination = current + offset
        guard ids.indices.contains(destination) else { return nil }
        return ids[destination]
    }
}
