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

/// Tab, ⇧Tab and the arrows in the passage picker.
///
/// macOS was measured first: a picker built of `.focusable()` views, driven
/// with synthesised key presses, moved focus once and then stopped, because
/// tabbing between arbitrary controls waits on a System Settings switch that
/// is off by default. These rules are what the picker moves focus by instead.
struct PassagePickerKeysTests {
    private typealias Stop = LampPassagePickerStop
    private typealias Keys = LampPassagePickerKeys

    // MARK: - Which stops there are

    /// Nothing typed, so nothing offered: the field, the translation and the
    /// two columns.
    @Test func anUntouchedReaderPickerRingsTheFieldTheTranslationAndTheColumns() {
        #expect(Keys.ring(offer: false, passages: true, duplicate: false)
            == [.field, .translation, .books, .chapters])
    }

    /// The offer row sits under the field, and is tabbed to from it.
    @Test func whatIsTypedAddsItsOfferAfterTheField() {
        #expect(Keys.ring(offer: true, passages: true, duplicate: false)
            == [.field, .offer, .translation, .books, .chapters])
    }

    /// While the books load there are no columns to tab into, and nothing in
    /// them to arrow through.
    @Test func loadingBooksLeavesTheColumnsOutOfTheRing() {
        #expect(Keys.ring(offer: false, passages: false, duplicate: false)
            == [.field, .translation])
    }

    /// A new tab's picker ends with the row that opens one where this is.
    @Test func aNewTabsDuplicateRowIsTheLastStop() {
        #expect(Keys.ring(offer: true, passages: true, duplicate: true).last == .duplicate)
    }

    // MARK: - Moving round the ring

    @Test func tabGoesForwardAndShiftTabBack() {
        let ring = Keys.ring(offer: true, passages: true, duplicate: false)
        #expect(Keys.stepping(from: .field, by: 1, through: ring) == .offer)
        #expect(Keys.stepping(from: .books, by: -1, through: ring) == .translation)
    }

    /// A popover is a closed set of controls: tabbing past the last lands on
    /// the field, where the next thing typed should go.
    @Test func theRingWrapsBothWays() {
        let ring = Keys.ring(offer: false, passages: true, duplicate: false)
        #expect(Keys.stepping(from: .chapters, by: 1, through: ring) == .field)
        #expect(Keys.stepping(from: .field, by: -1, through: ring) == .chapters)
    }

    /// The offer row disappears the moment what was typed stops being an
    /// offer, and it may have had focus. Tab must still go somewhere.
    @Test func aStopThatHasLeftTheRingHandsFocusToTheField() {
        let ring = Keys.ring(offer: false, passages: true, duplicate: false)
        #expect(Keys.stepping(from: .offer, by: 1, through: ring) == .field)
        #expect(Keys.stepping(from: nil, by: 1, through: ring) == .field)
    }

    @Test func aRingOfNothingHasNowhereToGo() {
        #expect(Keys.stepping(from: .field, by: 1, through: []) == nil)
    }

    // MARK: - Tab in the chapter grid

    /// The grid is not one stop: Tab walks its chapters.
    @Test func tabStepsThroughTheChaptersOneAtATime() {
        #expect(Keys.chapterTab(from: 8, by: 1, of: 50) == .chapter(9))
        #expect(Keys.chapterTab(from: 8, by: -1, of: 50) == .chapter(7))
    }

    /// Tab past the last chapter, or back past the first, leaves the grid for
    /// the next stop round the ring — the only way out of Psalms by Tab.
    @Test func tabOffEitherEndOfTheGridLeavesIt() {
        #expect(Keys.chapterTab(from: 176, by: 1, of: 176) == .leave)
        #expect(Keys.chapterTab(from: 1, by: -1, of: 176) == .leave)
    }

    /// A single-chapter book is both ends at once, so Tab passes straight
    /// through it either way.
    @Test func aOneChapterBookIsTabbedStraightThrough() {
        #expect(Keys.chapterTab(from: 1, by: 1, of: 1) == .leave)
        #expect(Keys.chapterTab(from: 1, by: -1, of: 1) == .leave)
    }

    /// A book whose chapters have not arrived has nothing to tab through.
    @Test func aBookWithNoChaptersIsLeftImmediately() {
        #expect(Keys.chapterTab(from: 1, by: 1, of: 0) == .leave)
    }

    // MARK: - Arrows in the chapter grid

    @Test func upAndDownMoveByAWholeRowAndLeftAndRightByOne() {
        #expect(Keys.chapter(from: 8, by: Keys.chapterColumns, of: 50) == 13)
        #expect(Keys.chapter(from: 8, by: -Keys.chapterColumns, of: 50) == 3)
        #expect(Keys.chapter(from: 8, by: 1, of: 50) == 9)
        #expect(Keys.chapter(from: 8, by: -1, of: 50) == 7)
    }

    /// Down from the part-filled last row lands on the last chapter rather
    /// than on nothing: in Psalms, down from 174 reaches 176.
    @Test func aStepOffTheEndLandsOnTheLastChapter() {
        #expect(Keys.chapter(from: 174, by: Keys.chapterColumns, of: 176) == 176)
        #expect(Keys.chapter(from: 176, by: 1, of: 176) == 176)
    }

    @Test func theGridDoesNotWrapPastTheFirstChapter() {
        #expect(Keys.chapter(from: 3, by: -Keys.chapterColumns, of: 50) == 1)
        #expect(Keys.chapter(from: 1, by: -1, of: 50) == 1)
    }

    /// A book whose chapters have not arrived yet has one chapter to be on.
    @Test func aBookWithNoChaptersStaysAtOne() {
        #expect(Keys.chapter(from: 4, by: 1, of: 0) == 1)
    }

    // MARK: - Arrows in a list

    @Test func arrowsStepThroughTheRowsAndStopAtTheEnds() {
        #expect(Keys.row(from: 3, by: 1, of: 10) == 4)
        #expect(Keys.row(from: 3, by: -1, of: 10) == 2)
        #expect(Keys.row(from: 9, by: 1, of: 10) == 9)
        #expect(Keys.row(from: 0, by: -1, of: 10) == 0)
    }

    /// Typing narrows the books to ones the chosen book is not among, so the
    /// first arrow has no row to step from: it selects the first match.
    @Test func withNothingSelectedAnArrowTakesTheFirstRow() {
        #expect(Keys.row(from: nil, by: 1, of: 10) == 0)
        #expect(Keys.row(from: 40, by: -1, of: 10) == 0)
    }

    @Test func anEmptyListHasNoRowToStepTo() {
        #expect(Keys.row(from: nil, by: 1, of: 0) == nil)
    }
}
