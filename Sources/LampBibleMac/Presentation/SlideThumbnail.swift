import LampCore
import LampPresentationUI
import SwiftUI

/// One slide in the studio's strip, drawn only when that slide or the deck's
/// look changes.
///
/// Equatable so SwiftUI can skip it. Everything that changes while moving
/// between slides — which one is selected, where the strip is scrolled — is
/// deliberately not an input here, because drawing a slide costs real work:
/// a picture behind one has its page laid out three times, once hidden to
/// find where the words fall, once to scrim them and once to set them in the
/// colours read from underneath. Multiplied by every slide in the deck, on
/// every keystroke, that is what made moving between slides slow.
///
/// The style, rather than the whole deck, is the other input on purpose:
/// editing the text of one slide then redraws that slide, not all of them.
struct SlideThumbnail: View, Equatable {
    let slide: LampPresentationSlide
    let style: LampPresentationSlideStyle
    let store: LampPresentationDeckStore

    /// The store is left out because it addresses the library this window
    /// was opened on and does not change while it is open. If decks ever
    /// move between libraries without the window being rebuilt, it belongs
    /// in here.
    static func == (lhs: SlideThumbnail, rhs: SlideThumbnail) -> Bool {
        lhs.slide == rhs.slide && lhs.style == rhs.style
    }

    var body: some View {
        LampPresentationSlideCanvas(
            slide: slide,
            style: style,
            compact: true,
            assetURL: { store.assetURL(for: $0) }
        )
        .aspectRatio(style.aspectRatio.ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
