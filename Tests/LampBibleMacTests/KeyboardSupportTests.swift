import Foundation
import Testing
@testable import LampBibleMacSupport

/// The embedded terminal has no settings for someone to configure, so the Mac
/// editing keys SwiftTerm leaves unserved are served by Lamp.
///
/// The "should send" bytes are readline's, which is what the provider CLIs
/// read. The "SwiftTerm sends" halves were measured by driving its `keyDown`
/// and recording what came out, not assumed.
struct KeyboardSupportTests {
    private typealias Key = LampTerminalKeyChord.Key

    private func bytes(
        _ keyCode: UInt16,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) -> [UInt8]? {
        LampTerminalKeyMap.bytes(for: LampTerminalKeyChord(
            keyCode: keyCode, command: command, option: option, control: control, shift: shift
        ))
    }

    // MARK: - What was broken

    /// SwiftTerm sent nothing at all: it routes ⌘⌫ to `deleteToBeginningOfLine:`
    /// and has no handler for it.
    @Test func commandBackspaceKillsToTheStartOfTheLine() {
        #expect(bytes(Key.delete, command: true) == [0x15])
    }

    @Test func commandForwardDeleteKillsToTheEndOfTheLine() {
        #expect(bytes(Key.forwardDelete, command: true) == [0x0B])
    }

    /// SwiftTerm treated Command like Option and moved by a word.
    @Test func commandArrowsReachTheEndsOfTheLineRatherThanTheNextWord() {
        #expect(bytes(Key.leftArrow, command: true) == [0x01])
        #expect(bytes(Key.rightArrow, command: true) == [0x05])
    }

    /// SwiftTerm sent `1B EF 9C A8` — ESC followed by the UTF-8 of the private
    /// -use scalar macOS uses for the key, which means nothing to any program.
    @Test func optionForwardDeleteKillsTheWordAhead() {
        #expect(bytes(Key.forwardDelete, option: true) == [0x1B, 0x64])
    }

    @Test func homeAndEndAreSentAtAll() {
        #expect(bytes(Key.home) == [0x1B, 0x5B, 0x48])
        #expect(bytes(Key.end) == [0x1B, 0x5B, 0x46])
    }

    @Test func shiftReturnStillInsertsALineRatherThanSubmittingOne() {
        #expect(bytes(Key.returnKey, shift: true) == [0x1B, 0x0D])
        #expect(bytes(Key.keypadEnter, shift: true) == [0x1B, 0x0D])
    }

    // MARK: - What must be left alone

    /// ⌥⌫ already sends `1B 7F`, which is what every terminal sends. Claiming
    /// it here would replace a working sequence with a guess.
    @Test func optionBackspaceIsLeftToTheTerminalView() {
        #expect(bytes(Key.delete, option: true) == nil)
    }

    @Test func plainKeysAreLeftToTheTerminalView() {
        #expect(bytes(Key.delete) == nil)
        #expect(bytes(Key.leftArrow) == nil)
        #expect(bytes(Key.rightArrow) == nil)
        #expect(bytes(Key.returnKey) == nil)
        #expect(bytes(Key.forwardDelete) == nil)
    }

    /// A chord carrying more than the map asks for belongs to someone else:
    /// ⇧⌘← selects, and ⌃⌘← is Spaces.
    @Test func extraModifiersMeanTheChordIsNotOurs() {
        #expect(bytes(Key.leftArrow, command: true, shift: true) == nil)
        #expect(bytes(Key.leftArrow, command: true, control: true) == nil)
        #expect(bytes(Key.delete, command: true, option: true) == nil)
        #expect(bytes(Key.returnKey, command: true, shift: true) == nil)
    }

    /// Control sequences are SwiftTerm's own business and it gets them right.
    @Test func controlChordsAreLeftAlone() {
        #expect(bytes(Key.leftArrow, control: true) == nil)
        #expect(bytes(Key.delete, control: true) == nil)
    }
}

/// Arrow keys step the selection through the slide navigator.
struct SlideSelectionSteppingTests {
    private let deck = ["a", "b", "c"]

    @Test func anArrowMovesToTheNeighbouringSlide() {
        #expect(LampSlideSelection.stepping(from: "b", by: 1, through: deck) == "c")
        #expect(LampSlideSelection.stepping(from: "b", by: -1, through: deck) == "a")
    }

    /// Held down at the end of a deck, an arrow stops rather than reappearing
    /// at the other end — nil means "stay where you are".
    @Test func theEndsOfTheDeckDoNotWrap() {
        #expect(LampSlideSelection.stepping(from: "c", by: 1, through: deck) == nil)
        #expect(LampSlideSelection.stepping(from: "a", by: -1, through: deck) == nil)
    }

    /// One press should select something rather than nothing.
    @Test func withNothingSelectedTheFirstSlideIsTheStartingPoint() {
        #expect(LampSlideSelection.stepping(from: nil, by: 1, through: deck) == "a")
        #expect(LampSlideSelection.stepping(from: nil, by: -1, through: deck) == "a")
    }

    /// A slide deleted from under the selection leaves an id that is no longer
    /// in the deck; an arrow should recover rather than do nothing forever.
    @Test func aSelectionThatIsNoLongerInTheDeckRecovers() {
        #expect(LampSlideSelection.stepping(from: "gone", by: 1, through: deck) == "a")
    }

    @Test func anEmptyDeckHasNowhereToGo() {
        #expect(LampSlideSelection.stepping(from: nil, by: 1, through: []) == nil)
        #expect(LampSlideSelection.stepping(from: "a", by: 1, through: []) == nil)
    }
}
