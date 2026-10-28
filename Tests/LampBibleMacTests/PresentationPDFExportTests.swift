import AppKit
import CoreGraphics
import Foundation
import LampCore
import PDFKit
import Testing
@testable import LampBibleMacSupport

/// Exporting a deck as a PDF.
///
/// The page geometry is checked because it is what decides whether the deck
/// prints and imports elsewhere without being rescaled, and the text because a
/// page of words drawn as a picture looks identical and is useless: nothing can
/// search it, select from it, or print it sharply.
@MainActor
struct PresentationPDFExportTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func export(
        _ deck: LampPresentationDeck,
        in root: URL,
        options: LampPresentationPDFExport.Options = .init()
    ) async throws -> PDFDocument {
        let destination = root.appendingPathComponent("deck.pdf")
        try await LampPresentationPDFExport.write(
            deck: deck,
            store: LampPresentationDeckStore(rootURL: root),
            to: destination,
            options: options
        )
        return try #require(PDFDocument(url: destination))
    }

    /// Extracted PDF text with the layout's own line breaks collapsed.
    ///
    /// A line break falls wherever the measure ran out, so a sentence that set
    /// across two lines comes back with a newline inside it. Searching the raw
    /// extraction for a phrase therefore fails on exactly the long notes this
    /// is meant to check.
    private func flattened(_ pdf: PDFDocument) -> String {
        (pdf.string ?? "").replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
    }

    private func withNotes(_ notes: [String]) -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        deck.slides = notes.enumerated().map { index, note in
            LampPresentationSlide(
                layout: .titleAndBody,
                blocks: [
                    .init(kind: .title, text: "Slide \(index + 1)"),
                    .init(kind: .body, text: "Body \(index + 1)"),
                ],
                speakerNotes: note
            )
        }
        return deck
    }

    /// A slide hidden from the presentation stays out of the handout too. The
    /// exported file is often the copy other people keep, and a slide cut for
    /// time or left unfinished should not be the version they read.
    @Test func ahiddenSlideIsNotExported() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        let visible = deck.slides.count
        deck.slides[0].isHidden = true

        let pdf = try await export(deck, in: root)

        #expect(pdf.pageCount == visible - 1)
    }

    /// Hiding every slide is not the same as having none, and saying "no
    /// slides" would send someone looking for slides that are all there.
    @Test func adeckWhoseSlidesAreAllHiddenSaysSo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        for index in deck.slides.indices { deck.slides[index].isHidden = true }

        await #expect(throws: LampPresentationPDFExport.ExportError.allSlidesHidden) {
            _ = try await export(deck, in: root)
        }
    }

    @Test func eachSlideBecomesOnePage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = LampPresentationDeck.starter(title: "Psalm 23")

        let pdf = try await export(deck, in: root)

        #expect(pdf.pageCount == deck.slides.count)
        for index in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: index))
            let box = page.bounds(for: .mediaBox)
            #expect(box.size == CGSize(width: 960, height: 540), "page \(index + 1)")
        }
    }

    /// Drawn into the PDF rather than rasterised into it, so the words are
    /// still words.
    @Test func thePagesCarryTheSlidesWordsAsText() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = LampPresentationDeck.starter(title: "Psalm 23")

        let pdf = try await export(deck, in: root)
        let text = pdf.string ?? ""

        #expect(text.contains("Psalm 23"))
        #expect(text.contains("Main Idea"))
        #expect(text.contains("Reflection"))
    }

    /// The deck's title, so a reader's window and a file listing name the deck
    /// rather than the filename someone happened to choose.
    @Test func theDocumentIsTitledAfterTheDeck() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = try await export(LampPresentationDeck.starter(title: "Psalm 23"), in: root)

        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Psalm 23")
    }

    @Test func astandardDeckGetsTheNarrowerPage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        deck.aspectRatio = .standard

        let pdf = try await export(deck, in: root)

        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.size == CGSize(width: 720, height: 540))
    }

    /// Both page sizes are 7½ inches tall, which is what lets a deck of either
    /// shape print on the same paper.
    @Test func bothPageShapesAreTheSameHeight() {
        #expect(LampPresentationPDFExport.pageSize(for: .widescreen).height == 540)
        #expect(LampPresentationPDFExport.pageSize(for: .standard).height == 540)
    }

    @Test func adeckWithNoSlidesIsRefusedRatherThanWritingAnUnopenablePDF() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = LampPresentationDeck.starter(title: "Psalm 23")
        deck.slides = []

        await #expect(throws: LampPresentationPDFExport.ExportError.noSlides) {
            try await LampPresentationPDFExport.write(
                deck: deck,
                store: LampPresentationDeckStore(rootURL: root),
                to: root.appendingPathComponent("deck.pdf")
            )
        }
    }

    // MARK: - A picture behind the words

    /// Writes a backdrop that forces Lamp to lay a scrim: light and dark in the
    /// same band, so no single ink colour can be read over all of it. A flat
    /// picture simply flips the words to dark and needs no scrim, and it was
    /// exactly such a picture that made this bug look fixed when it was not.
    private func backdropNeedingAScrim(in store: LampPresentationDeckStore) throws {
        try FileManager.default.createDirectory(
            at: store.assetsDirectoryURL, withIntermediateDirectories: true
        )
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_600, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for x in stride(from: 0, to: 1_600, by: 40) {
            let value = (x / 40) % 2 == 0 ? 0.05 : 0.85
            NSColor(calibratedRed: value, green: value * 0.95, blue: value * 0.9, alpha: 1).setFill()
            NSRect(x: x, y: 0, width: 40, height: 900).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!
            .write(to: store.assetsDirectoryURL.appendingPathComponent("bg.png"))
    }

    private func deckOverAPicture() -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: "Over A Picture")
        deck.slides = [
            LampPresentationSlide(layout: .titleAndBody, blocks: [
                .init(
                    kind: .image, text: "", assetPath: "Assets/bg.png",
                    altText: "Stripes", placement: .background
                ),
                .init(kind: .title, text: "Words Over A Picture"),
                .init(kind: .body, text: "The picture must still be visible behind these words."),
            ]),
        ]
        return deck
    }

    /// How many distinct colours a page draws, sampled. A page that lost its
    /// picture is one flat colour with words on it; a page that kept it is
    /// hundreds.
    private func sampledColours(_ pdf: PDFDocument, page index: Int) throws -> Int {
        let url = try #require(pdf.documentURL)
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: index + 1))
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width), height = Int(box.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(page)
        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        var seen = Set<Int>()
        for x in stride(from: 4, to: width, by: 11) {
            for y in stride(from: 4, to: height, by: 11) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                seen.insert(
                    Int(colour.redComponent * 255) << 16
                        | Int(colour.greenComponent * 255) << 8
                        | Int(colour.blueComponent * 255)
                )
            }
        }
        return seen.count
    }

    /// The bug this guards: Lamp sets words over a picture with feathered
    /// gradients, those lose their transparency when drawn into a PDF context
    /// and paint flat edge to edge, and the page came out one colour with the
    /// picture embedded in the file but never visible.
    @Test func apictureBehindTheWordsIsStillVisibleOnThePage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        try backdropNeedingAScrim(in: store)

        let pdf = try await export(deckOverAPicture(), in: root)

        #expect(
            try sampledColours(pdf, page: 0) > 50,
            "the page is nearly one colour, so the picture behind the words was lost"
        )
    }

    @Test func apictureBehindTheWordsSurvivesOnANotesPageToo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        try backdropNeedingAScrim(in: store)

        let pdf = try await export(
            deckOverAPicture(), in: root, options: .init(includesSpeakerNotes: true)
        )

        #expect(try sampledColours(pdf, page: 0) > 50)
    }

    /// The price of the above, written down so it is a decision rather than a
    /// surprise: a slide with a picture behind it goes on the page as one
    /// image, so its words are no longer selectable. Every other slide's are.
    @Test func wordsOverAPictureAreNoLongerSelectableButEveryOtherSlidesAre() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampPresentationDeckStore(rootURL: root)
        try backdropNeedingAScrim(in: store)
        var deck = deckOverAPicture()
        deck.slides.append(
            LampPresentationSlide(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "An Ordinary Slide"),
                .init(kind: .body, text: "No picture behind this one."),
            ])
        )

        let text = flattened(try await export(deck, in: root))

        #expect(text.contains("Words Over A Picture") == false)
        #expect(text.contains("An Ordinary Slide"))
    }

    // MARK: - With speaker notes

    @Test func notesPagesAreUprightPaperWithTheNotesOnThem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = withNotes(["Open gently, then slow down.", "Land on the shepherd."])

        let pdf = try await export(deck, in: root, options: .init(includesSpeakerNotes: true))

        #expect(pdf.pageCount == 2)
        let box = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.size == CGSize(width: 612, height: 792), "US Letter, upright")
        let text = flattened(pdf)
        #expect(text.contains("Open gently, then slow down."))
        #expect(text.contains("Land on the shepherd."))
        #expect(text.contains("Slide 1"), "the slide itself is still drawn on the page")
    }

    /// Notes that follow a manuscript are paragraphs of a talk, so overflowing
    /// a page is the ordinary case. The remainder has to carry on rather than
    /// be silently cut off.
    @Test func notesTooLongForOnePageCarryOnToTheNext() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ending = "This sentence has to survive to the end."
        let long = String(
            repeating: "The shepherd leads his sheep beside still waters, and they follow. ",
            count: 120
        ) + ending

        let pdf = try await export(
            withNotes([long]), in: root, options: .init(includesSpeakerNotes: true)
        )

        #expect(pdf.pageCount > 1, "one slide's notes spilled onto further pages")
        #expect(flattened(pdf).contains(ending), "nothing was cut off the end")
        #expect(flattened(pdf).contains("(continued)"))
    }

    @Test func aslideWithNoNotesStillGetsItsPage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = try await export(
            withNotes(["", "Only this one speaks.", ""]),
            in: root,
            options: .init(includesSpeakerNotes: true)
        )

        #expect(pdf.pageCount == 3)
    }

    /// Asking for notes must not change what the slides-only export does.
    @Test func theSlidesOnlyExportIsUnaffectedByTheNotesOption() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = try await export(withNotes(["Notes here."]), in: root)

        #expect(pdf.pageCount == 1)
        #expect(try #require(pdf.page(at: 0)).bounds(for: .mediaBox).size
            == CGSize(width: 960, height: 540))
        #expect(flattened(pdf).contains("Notes here.") == false, "notes are not on a slide")
    }

    @Test func everyPageIsReportedAsItIsFinished() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let deck = LampPresentationDeck.starter(title: "Psalm 23")
        var reported: [(Int, Int)] = []

        try await LampPresentationPDFExport.write(
            deck: deck,
            store: LampPresentationDeckStore(rootURL: root),
            to: root.appendingPathComponent("deck.pdf"),
            progress: { reported.append(($0, $1)) }
        )

        #expect(reported.map(\.0) == Array(1...deck.slides.count))
        #expect(reported.allSatisfy { $0.1 == deck.slides.count })
    }
}
