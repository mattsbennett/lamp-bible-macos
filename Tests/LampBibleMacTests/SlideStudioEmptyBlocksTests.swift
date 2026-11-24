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

/// A picture block is headed by what it shows.
struct SlideStudioBlockNameTests {
    @Test func aPictureBlockIsNamedForWhatItShows() {
        var block = LampPresentationBlock(kind: .image, assetPath: "Assets/still.jpg")
        #expect(block.studioName == "Image")
        block.video = "Assets/loop.mp4"
        #expect(block.studioName == "Looping Video")
        block.clip = .init(source: "https://youtu.be/dQw4w9WgXcQ")
        #expect(block.studioName == "Clip")
        #expect(LampPresentationBlock(kind: .title, text: "Hi").studioName == "Title")
    }
}

/// A copied file keeps a readable form of its name.
struct SlideStudioAssetNameTests {
    @Test func aCopyIsNamedAfterItsFile() {
        let name = SlideStudioAssetName.copy(
            of: URL(fileURLWithPath: "/tmp/Église at Dusk (2).JPG"), extension: "HEIC", fallback: "picture"
        )
        #expect(name.hasPrefix("eglise-at-dusk-2-"))
        #expect(name.hasSuffix(".heic"))
        #expect(name.count == "eglise-at-dusk-2-".count + 8 + ".heic".count)
        #expect(LampPresentationDeckValidator.isSafeAssetPath("Assets/" + name))
        #expect(SlideStudioAssetName.stem("日本", fallback: "video") == "video")
        #expect(SlideStudioAssetName.stem(String(repeating: "a", count: 60), fallback: "x").count == 40)
    }
}

/// An issue is placed by slide and block, not by its path.
struct SlideStudioIssuePlaceTests {
    @Test func anIssueIsNamedBySlideAndBlock() {
        let deck = LampPresentationDeck(title: "Talk", slides: [
            .init(layout: .title, blocks: [.init(kind: .title, text: "Hi")]),
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "Watch"),
                .init(kind: .image, assetPath: "Assets/a.jpg", clip: .init(source: "https://youtu.be/dQw4w9WgXcQ")),
            ]),
        ])
        #expect(SlideStudioIssuePlace.name(of: "slides[1].blocks[1].altText", in: deck) == "Slide 2, Clip")
        #expect(SlideStudioIssuePlace.name(of: "slides[0].blocks", in: deck) == "Slide 1")
        #expect(SlideStudioIssuePlace.name(of: "slides[0].blocks[7].text", in: deck) == "Slide 1")
        #expect(SlideStudioIssuePlace.name(of: "theme", in: deck) == "Deck")
    }
}
