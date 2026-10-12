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
        Set(
            LampPresentationDeckValidator.validate(deck)
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
