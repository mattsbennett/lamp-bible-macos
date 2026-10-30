import Foundation
import LampModuleKit

/// The text measurements this app has, beyond the two it shares with the phone.
///
/// `LampTextScale` itself is core's, as are `bookText` and `bookLineSpacing`:
/// both apps read the same books, and a size set on one should mean the same
/// thing on the other. The rest are surfaces only this app has.
public extension LampTextScale {
    /// Scripture quoted inside a list or a side panel — a search hit, an
    /// occurrence row, a rendering in the analysis.
    ///
    /// Follows the reader's own setting rather than a fixed caption size,
    /// which was the one place in the app that setting did not reach. A
    /// little smaller than the reader, because these are glimpses of the text
    /// among other things rather than the text itself, and a list of them at
    /// full reading size shows two of them at once. Never below the reader
    /// scale's own floor.
    static func studyText(readerSize: Double) -> Double {
        max(readerText.minimum, readerSize - 4)
    }

    /// Scripture is the one thing on screen a reader stares at for an hour, so it
    /// stretches further in both directions than the study panels beside it.
    static let readerText = LampTextScale(
        minimum: 14,
        maximum: 34,
        step: 1,
        defaultValue: 20
    )

    static let readerLineSpacing = LampTextScale(
        minimum: 2,
        maximum: 16,
        step: 1,
        defaultValue: 7
    )

    /// Commentary is prose about the text rather than the text itself, and it sits
    /// in a narrow panel, so it starts near the system body size.
    static let commentaryText = LampTextScale(
        minimum: 11,
        maximum: 26,
        step: 1,
        defaultValue: 13
    )

    /// Commentary runs to dense paragraphs of it; the default is deliberately
    /// looser than the near-zero spacing SwiftUI gives a plain `Text`.
    static let commentaryLineSpacing = LampTextScale(
        minimum: 0,
        maximum: 14,
        step: 1,
        defaultValue: 6
    )

    /// Quiz cards need to stay compact beside a plan reading, but their prompts
    /// benefit from a larger starting size than dense commentary paragraphs.
    static let quizText = LampTextScale(
        minimum: 11,
        maximum: 30,
        step: 1,
        defaultValue: 17
    )

    static let quizLineSpacing = LampTextScale(
        minimum: 0,
        maximum: 14,
        step: 1,
        defaultValue: 5
    )

    /// A writing as its readers meet it, on its own page. It stretches as far as
    /// scripture does: a writer proofreading their own prose zooms in further
    /// than a reader ever does.
    static let writingReadingText = LampTextScale(
        minimum: 13,
        maximum: 32,
        step: 1,
        defaultValue: 17
    )

    static let writingReadingLineSpacing = LampTextScale(
        minimum: 0,
        maximum: 16,
        step: 1,
        defaultValue: 6
    )

    /// The Markdown source surface. Monospaced text reads smaller than prose at the
    /// same point size, so it starts below the size the writing is read at.
    static let writingEditorText = LampTextScale(
        minimum: 11,
        maximum: 24,
        step: 1,
        defaultValue: 15
    )
}
