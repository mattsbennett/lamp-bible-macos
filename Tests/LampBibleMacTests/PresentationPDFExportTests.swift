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
