import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// A heading cleared in Slide Studio leaves the slide without it, rather
/// than making a deck that cannot be saved or presented.
struct SlideStudioEmptyBlocksTests {
    @Test func clearedTextBlocksAreLeftOutAndPicturesKept() {
        let deck = LampPresentationDeck(title: "Talk", slides: [
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "  \n"),
                .init(kind: .image, assetPath: "Assets/still.jpg", altText: "Still", placement: .background,
                      clip: .init(source: "https://youtu.be/dQw4w9WgXcQ")),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Kept"),
                .init(kind: .body, text: ""),
            ]),
        ])
        #expect(!LampPresentationDeckValidator.errors(in: deck).isEmpty)
        let stored = deck.withoutEmptyTextBlocks
        #expect(stored.slides[0].blocks.map(\.kind) == [.image])
        #expect(stored.slides[1].blocks.map(\.text) == ["Kept"])
        #expect(LampPresentationDeckValidator.errors(in: stored).isEmpty)
        // Nothing cleared, nothing changed.
        #expect(stored.withoutEmptyTextBlocks == stored)
    }
}
