import Foundation
import LampCore
import Testing

/// The skill ships a Python validator an agent runs before Lamp ever sees the
/// deck, and Lamp validates again in Swift. Two implementations of one rule set
/// drift, and when they do an agent is told a deck is fine and then watches it
/// behave differently. These hold them to the same answers.
struct DeckValidatorAgreementTests {
    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LampBibleMac/Resources/AgentSkills/build-lamp-deck/scripts/validate_deck.py"
            )
    }

    /// Warning locations only: the two phrase their advice differently, and
    /// holding them to identical prose would be a test of wording, not rules.
    private func pythonWarningPaths(for deck: LampPresentationDeck) throws -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deckURL = directory.appendingPathComponent("presentation.lampdeck")
        try JSONEncoder().encode(deck).write(to: deckURL)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path, deckURL.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("WARNING ") }
                .compactMap { line in
                    line.dropFirst("WARNING ".count).split(separator: ":").first.map(String.init)
                }
        )
    }

    private func swiftWarningPaths(for deck: LampPresentationDeck) -> Set<String> {
        // The script looks for each image beside the deck, which it is handed
        // in an empty folder, so here too no image is there.
        Set(
            LampPresentationDeckValidator.validate(deck, assetExists: { _ in false })
                .filter { $0.severity == .warning }
                .map(\.path)
        )
    }

    @Test(arguments: [
        // A heading on a layout that is set without one.
        LampPresentationDeck(title: "Heading", slides: [
            .init(layout: .scripture, blocks: [
                .init(kind: .title, text: "A heading"),
                .init(kind: .scripture, text: "In the beginning was the Word."),
            ]),
        ]),
        // A third column, and a caption with no picture.
        LampPresentationDeck(title: "Spill", slides: [
            .init(layout: .twoColumn, blocks: [
                .init(kind: .title, text: "Two ideas"),
                .init(kind: .body, text: "First"),
                .init(kind: .body, text: "Second"),
                .init(kind: .body, text: "Third"),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Body"),
                .init(kind: .caption, text: "Stranded"),
            ]),
        ]),
        // Headed columns with their citations, then what two columns cannot
        // hold: a third column, and a citation with nothing to attribute.
        LampPresentationDeck(title: "Columns", slides: [
            .init(layout: .twoColumn, blocks: [
                .init(kind: .title, text: "Two searches"),
                .init(kind: .subtitle, text: "The Preacher"),
                .init(kind: .scripture, text: "to seek wisdom and the scheme of things"),
                .init(kind: .citation, text: "Ecclesiastes 7:25"),
                .init(kind: .subtitle, text: "Mankind"),
                .init(kind: .scripture, text: "they have sought out many schemes."),
                .init(kind: .citation, text: "Ecclesiastes 7:29"),
            ]),
            .init(layout: .twoColumn, blocks: [
                .init(kind: .citation, text: "Stranded"),
                .init(kind: .subtitle, text: "One"),
                .init(kind: .body, text: "First"),
                .init(kind: .subtitle, text: "Two"),
                .init(kind: .body, text: "Second"),
                .init(kind: .citation, text: "Its source"),
                .init(kind: .citation, text: "A second source"),
                .init(kind: .subtitle, text: "Three"),
                .init(kind: .body, text: "Third"),
            ]),
        ]),
        // Two credited passages under each heading, which both validators
        // now draw in full, and a trailing passage with no citation.
        LampPresentationDeck(title: "Paired", slides: [
            .init(layout: .twoColumn, blocks: [
                .init(kind: .title, text: "Two attitudes"),
                .init(kind: .subtitle, text: "Resignation"),
                .init(kind: .quotation, text: "Nothing to be done."),
                .init(kind: .citation, text: "Beckett"),
                .init(kind: .scripture, text: "We will not walk in it."),
                .init(kind: .citation, text: "Jeremiah 6:16"),
                .init(kind: .subtitle, text: "Expectancy"),
                .init(kind: .quotation, text: "Yet I will look again."),
                .init(kind: .citation, text: "Jonah 2:4"),
                .init(kind: .body, text: "And a thought of my own."),
            ]),
        ]),
        // Pictures behind slides: one on a title slide credited by its
        // caption, one under a column slide whose caption has nothing to
        // credit once a second caption arrives, and a second background
        // that has nowhere to go.
        LampPresentationDeck(title: "Backgrounds", slides: [
            .init(layout: .title, blocks: [
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A city", placement: .background),
                .init(kind: .title, text: "Title"),
                .init(kind: .caption, text: "Thomas Cole"),
            ]),
            .init(layout: .twoColumn, blocks: [
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A city", placement: .background),
                .init(kind: .body, text: "First"),
                .init(kind: .body, text: "Second"),
                .init(kind: .caption, text: "A credit"),
                .init(kind: .caption, text: "A second credit"),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A city", placement: .background),
                .init(kind: .title, text: "Title"),
                .init(kind: .body, text: "Body"),
                .init(kind: .image, assetPath: "Assets/b.jpg", altText: "A cover"),
                .init(kind: .image, assetPath: "Assets/c.jpg", altText: "Another", placement: .background),
            ]),
        ]),
        // A slide carrying more than it can show.
        LampPresentationDeck(title: "Crowded", slides: [
            .init(layout: .quotation, blocks: [
                .init(
                    kind: .quotation,
                    text: String(repeating: "Every word competing for the same room. ", count: 30)
                ),
            ]),
        ]),
        // Notes promised from a manuscript that no slide anchors.
        LampPresentationDeck(
            title: "Unanchored",
            source: .init(kind: .devotional, id: "abc"),
            slides: [
                .init(layout: .titleAndBody, blocks: [
                    .init(kind: .title, text: "Heading"),
                    .init(kind: .body, text: "Body"),
                ]),
            ],
            speakerNotesSource: .manuscript
        ),
        // Notes following a source that holds no prose.
        LampPresentationDeck(
            title: "Wrong source",
            source: .init(kind: .scripture, id: "john"),
            slides: [
                .init(
                    layout: .titleAndBody,
                    blocks: [.init(kind: .body, text: "Body")],
                    notesAnchor: "Somewhere"
                ),
            ],
            speakerNotesSource: .manuscript
        ),
        // A skip marker on content nobody checks.
        LampPresentationDeck(
            title: "Pointless skip",
            source: .init(kind: .devotional, id: "abc"),
            slides: [
                .init(
                    layout: .titleAndBody,
                    blocks: [
                        .init(kind: .body, text: "Body", manuscriptCheck: .skip),
                    ],
                    notesAnchor: "Somewhere"
                ),
            ],
            speakerNotesSource: .manuscript
        ),
        // Several passages sharing one attribution.
        LampPresentationDeck(title: "Pooled", slides: [
            .init(layout: .scripture, blocks: [
                .init(kind: .scripture, text: "then the LORD God formed the man of dust"),
                .init(kind: .scripture, text: "The first man was from the earth"),
                .init(kind: .citation, text: "Genesis 2:7; 1 Corinthians 15:47"),
            ]),
        ]),
        // Quotation marks the author typed, which Lamp would double.
        LampPresentationDeck(title: "Typed marks", slides: [
            .init(layout: .quotation, blocks: [
                .init(kind: .quotation, text: "\u{201C}A whole sentence.\u{201D}"),
                .init(kind: .citation, text: "A source"),
            ]),
        ]),
        // Each passage attributed on its own: nothing to say.
        LampPresentationDeck(title: "Paired", slides: [
            .init(layout: .scripture, blocks: [
                .init(kind: .scripture, text: "then the LORD God formed the man of dust"),
                .init(kind: .citation, text: "Genesis 2:7"),
                .init(kind: .scripture, text: "The first man was from the earth"),
                .init(kind: .citation, text: "1 Corinthians 15:47"),
            ]),
        ]),
        // A list beside one quotation: one thing quoted, not two.
        LampPresentationDeck(title: "List and quote", slides: [
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "The three dials"),
                .init(kind: .body, text: "Capacity\nAttention\nRestraint", listStyle: .unordered),
                .init(kind: .quotation, text: "A single quoted sentence from somewhere."),
                .init(kind: .citation, text: "A source"),
            ]),
        ]),
        // Nothing to say about a well-formed deck.
        LampPresentationDeck(title: "Clean", slides: [
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "One focused idea."),
                .init(kind: .citation, text: "A source"),
            ]),
        ]),
    ])
    func bothValidatorsPointAtTheSameBlocks(deck: LampPresentationDeck) throws {
        let fromPython = try pythonWarningPaths(for: deck)
        let fromSwift = swiftWarningPaths(for: deck)
        #expect(
            fromPython == fromSwift,
            "python said \(fromPython.sorted()), swift said \(fromSwift.sorted())"
        )
    }
}
