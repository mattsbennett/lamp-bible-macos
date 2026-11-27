import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

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
                "Sources/LampBibleMacSupport/Resources/AgentSkills/build-lamp-deck/scripts/validate_deck.py"
            )
    }

    /// Warning locations only: the two phrase their advice differently, and
    /// holding them to identical prose would be a test of wording, not rules.
    private func pythonWarningPaths(for deck: LampPresentationDeck) throws -> Set<String> {
        try pythonWarningPaths(forJSON: try JSONEncoder().encode(deck))
    }

    private func pythonWarningPaths(forJSON json: Data) throws -> Set<String> {
        Set(try pythonWarnings(forJSON: json).compactMap { line in
            line.split(separator: ":").first.map(String.init)
        })
    }

    /// The script's warnings, each `<path>: <message>`, with `files` beside
    /// the deck.
    private func pythonWarnings(
        forJSON json: Data, files: [String: Data] = [:], grow: [String: (Data, UInt64)] = [:]
    ) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deckURL = directory.appendingPathComponent("presentation.lampdeck")
        try json.write(to: deckURL)
        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // Written, then lengthened without writing: a large file that costs
        // no disk.
        for (path, (data, size)) in grow {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size)
            try handle.close()
        }

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

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("WARNING ") }
            .map { String($0.dropFirst("WARNING ".count)) }
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

    /// A box: size, type, body.
    private static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init) + Array(type.utf8) + body
    }

    /// A movie of one enabled video track whose entries are `codecs`, an
    /// H.264 one with `profile` in its `avcC`, its media `padding` bytes.
    private static func movie(_ codecs: String..., profile: UInt8? = nil, padding: Int = 0) -> Data {
        let handler = box("hdlr", [UInt8](repeating: 0, count: 8) + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
        let entries = codecs.flatMap { codec -> [UInt8] in
            let body: [UInt8] = profile.map { [UInt8](repeating: 0, count: 78) + box("avcC", [1, $0, 0, 30]) }
                ?? [UInt8](repeating: 0, count: 8)
            return withUnsafeBytes(of: UInt32(8 + body.count).bigEndian, Array.init) + Array(codec.utf8) + body
        }
        let stsd = box("stsd", [0, 0, 0, 0] + withUnsafeBytes(of: UInt32(codecs.count).bigEndian, Array.init) + entries)
        let tkhd = box("tkhd", [0, 0, 0, 1] + [UInt8](repeating: 0, count: 80))
        let trak = box("trak", tkhd + box("mdia", handler + box("minf", box("stbl", stsd))))
        return Data(box("ftyp", Array("isom".utf8) + [0, 0, 2, 0]) + box("moov", trak) + box("mdat", [UInt8](repeating: 0, count: padding)))
    }

    /// A video too big for a deck, or in a codec not every device plays:
    /// both validators warn at the same place, in the same words, and say
    /// nothing of one that fits.
    @Test func bothValidatorsWarnOfAVideoThatIsTooBigOrNotForEveryDevice() throws {
        let json = #"""
        {"schemaVersion":1,"id":"60910124-99b3-48ca-9310-11c63ed118c0","title":"D","aspectRatio":"widescreen",
         "theme":{"id":"lamp-dark","accentColor":"#F59E0B","backgroundColor":"#111827","foregroundColor":"#F9FAFB","typeface":"system-serif"},
         "source":{"id":"60910124-99b3-48ca-9310-11c63ed118c1","kind":"devotional"},
         "slides":[
          {"id":"3b184129-31c5-48c8-962e-fe79e2862cc8","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd64","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "video":"Assets/loop.mp4"}]},
          {"id":"3b184129-31c5-48c8-962e-fe79e2862cc9","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd65","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "clip":{"source":"Assets/clip.mov","starts":"click"}}]},
          {"id":"3b184129-31c5-48c8-962e-fe79e2862cca","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd66","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "video":"Assets/fine.mp4"}]},
          {"id":"3b184129-31c5-48c8-962e-fe79e2862ccb","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd67","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "video":"Assets/ten.mp4"}]},
          {"id":"3b184129-31c5-48c8-962e-fe79e2862ccc","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd68","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "video":"Assets/second.mp4"}]}]}
        """#
        let files: [String: Data] = [
            "Assets/a.jpg": Data("jpeg".utf8),
            // Lengthened past a loop's 100 MB below.
            "Assets/loop.mp4": Self.movie("avc1"),
            "Assets/clip.mov": Self.movie("apcn"),
            "Assets/fine.mp4": Self.movie("hvc1", padding: 64),
            "Assets/ten.mp4": Self.movie("avc1", profile: 110),
            "Assets/second.mp4": Self.movie("avc1", "av01"),
        ]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let loop = try FileHandle(forWritingTo: folder.appendingPathComponent("Assets/loop.mp4"))
        try loop.truncate(atOffset: 100_000_001)
        try loop.close()
        // The same files for the script, the large one grown the same way.
        var scriptFiles = files
        scriptFiles["Assets/loop.mp4"] = nil
        let deck = try LampPresentationDeckStore.decodeUnvalidated(Data(json.utf8))
        let fromSwift = LampDeckTools.validate(deckJSON: Data(json.utf8), workspace: folder).issues
            .filter { $0.message.contains("prepare_video") }
            .map { "\($0.path): \($0.message)" }
        let fromPython = try pythonWarnings(forJSON: Data(json.utf8), files: scriptFiles, grow: ["Assets/loop.mp4": (Self.movie("avc1"), 100_000_001)])
            .filter { $0.contains("prepare_video") }
        #expect(Set(fromPython) == Set(fromSwift), "python said \(fromPython), swift said \(fromSwift)")
        // A video reached through a linked folder is no one's to read.
        let linked = folder.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder.appendingPathComponent("Assets"))
        let throughLink = json.replacingOccurrences(of: "Assets/clip.mov", with: "Linked/clip.mov")
        #expect(!LampDeckTools.validate(deckJSON: Data(throughLink.utf8), workspace: folder).issues
            .contains { $0.message.contains("ProRes") })
        let linkedDeck = folder.appendingPathComponent("presentation.lampdeck")
        try Data(throughLink.utf8).write(to: linkedDeck)
        let script = Process()
        let output = Pipe()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        script.arguments = ["python3", scriptURL.path, linkedDeck.path]
        script.standardOutput = output
        script.standardError = FileHandle.nullDevice
        try script.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        script.waitUntilExit()
        #expect(printed.contains("Valid Lamp deck"), "\(printed)")
        #expect(!printed.contains("ProRes"))
        #expect(Set(fromSwift) == [
            "slides[0].blocks[0].video: 'Assets/loop.mp4' is 101 MB, over the 100 MB a deck carries for a moving background. Bring it in with prepare_video, which makes it smaller; if it is still over, shorten it.",
            "slides[1].blocks[0].clip: 'Assets/clip.mov' is ProRes video, which an iPhone or iPad may not play. Bring it in with prepare_video, which saves it as HEVC.",
            "slides[3].blocks[0].video: 'Assets/ten.mp4' is H.264 High 10 video, which an iPhone or iPad may not play. Bring it in with prepare_video, which saves it as HEVC.",
            "slides[4].blocks[0].video: 'Assets/second.mp4' is AV1 video, which an iPhone or iPad may not play. Bring it in with prepare_video, which saves it as HEVC.",
        ])
        _ = deck
    }

    /// A way of starting a clip this app does not know, which only a deck's
    /// text can carry: both validators say how it is read.
    @Test func bothValidatorsSayAnUnknownStartIsReadAsAClick() throws {
        let json = #"""
        {"schemaVersion":1,"id":"60910124-99b3-48ca-9310-11c63ed118c0","title":"D","aspectRatio":"widescreen",
         "theme":{"id":"lamp-dark","accentColor":"#F59E0B","backgroundColor":"#111827","foregroundColor":"#F9FAFB","typeface":"system-serif"},
         "source":{"id":"60910124-99b3-48ca-9310-11c63ed118c1","kind":"devotional"},
         "slides":[{"id":"3b184129-31c5-48c8-962e-fe79e2862cc8","layout":"image","isHidden":false,"speakerNotes":"",
           "blocks":[{"id":"3921b8a7-335a-4424-945b-bcb9d949bd64","kind":"image","text":"","assetPath":"Assets/a.jpg","altText":"A",
             "clip":{"source":"Assets/a.mp4","starts":"sometimes"}}]}]}
        """#
        let deck = try LampPresentationDeckStore.decodeUnvalidated(Data(json.utf8))
        let fromPython = try pythonWarningPaths(forJSON: Data(json.utf8))
        let fromSwift = swiftWarningPaths(for: deck)
        #expect(fromPython == fromSwift, "python said \(fromPython.sorted()), swift said \(fromSwift.sorted())")
        #expect(fromSwift.contains("slides[0].blocks[0].clip"))
        // And each says it, not only something at the same place.
        #expect(try pythonWarnings(forJSON: Data(json.utf8)).contains { $0.contains("'sometimes' is read as click") })
        #expect(LampPresentationDeckValidator.validate(deck).contains { $0.message.contains("'sometimes' is read as click") })
        // A starts left empty is no way of starting at all, to either.
        let empty = json.replacingOccurrences(of: #""starts":"sometimes""#, with: #""starts":null"#)
        #expect(try !pythonWarnings(forJSON: Data(empty.utf8)).contains { $0.contains("is read as click") })
        let emptyDeck = try LampPresentationDeckStore.decodeUnvalidated(Data(empty.utf8))
        #expect(!LampPresentationDeckValidator.validate(emptyDeck).contains { $0.message.contains("is read as click") })
    }

    @Test(arguments: [
        // A heading on a layout that is set without one.
        LampPresentationDeck(title: "Heading", slides: [
            .init(layout: .scripture, blocks: [
                .init(kind: .title, text: "A heading"),
                .init(kind: .scripture, text: "In the beginning was the Word."),
            ]),
        ]),
        // A fifth column, and a caption with no picture.
        LampPresentationDeck(title: "Spill", slides: [
            .init(layout: .twoColumn, blocks: [
                .init(kind: .title, text: "Five ideas"),
                .init(kind: .body, text: "First"),
                .init(kind: .body, text: "Second"),
                .init(kind: .body, text: "Third"),
                .init(kind: .body, text: "Fourth"),
                .init(kind: .body, text: "Fifth"),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Body"),
                .init(kind: .caption, text: "Stranded"),
            ]),
        ]),
        // Headed columns with their citations, then what four columns cannot
        // hold: a fifth column, and a citation with nothing to attribute.
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
                .init(kind: .subtitle, text: "Four"),
                .init(kind: .body, text: "Fourth"),
                .init(kind: .subtitle, text: "Five"),
                .init(kind: .body, text: "Fifth"),
            ]),
        ]),
        // A word slide draws its transliteration and its gloss, each once;
        // a second gloss is not drawn. A statement and a comparison on the
        // wrong layout are drawn plain.
        LampPresentationDeck(title: "Forms", slides: [
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "ἀγάπη"),
                .init(kind: .subtitle, text: "agapē"),
                .init(kind: .body, text: "love"),
                .init(kind: .body, text: "a second gloss"),
            ], variant: .word),
            .init(layout: .scripture, blocks: [
                .init(kind: .scripture, text: "In the beginning was the Word."),
            ], variant: .statement),
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "A title"),
                .init(kind: .subtitle, text: "One line"),
                .init(kind: .body, text: "Not drawn"),
            ], variant: .comparison),
            // A comparison with only one column to compare.
            .init(layout: .twoColumn, blocks: [
                .init(kind: .body, text: "Alone"),
            ], variant: .comparison),
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
                .init(kind: .scripture, text: "yet I shall again look upon your holy temple."),
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
        // Every way an emphasised phrase fails to draw as written, beside
        // entries that draw, and a highlight too dim for the background.
        LampPresentationDeck(
            title: "Emphasis",
            theme: .init(
                id: "lamp-dark",
                backgroundColor: "#111827",
                foregroundColor: "#F9FAFB",
                accentColor: "#F59E0B",
                highlights: ["grace": "#60A5FA", "dim": "#1E3A8A"]
            ),
            slides: [
                .init(layout: .scripture, blocks: [
                    .init(kind: .scripture, text: "the law and the law, by grace", emphasis: [
                        .init(text: "grace", highlight: "grace"),
                        .init(text: ""),
                        .init(text: "mercy"),
                        .init(text: "Law"),
                        .init(text: "law", occurrence: 0),
                        .init(text: "law", occurrence: 3),
                        .init(text: "law", highlight: "torah", occurrence: 2),
                        .init(text: "the law"),
                        .init(text: "aw"),
                    ]),
                    .init(kind: .citation, text: "A source"),
                ]),
                .init(layout: .image, blocks: [
                    .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A city", emphasis: [.init(text: "city")]),
                ]),
            ]
        ),
        // Where Swift's characters and Python's code points part: a composed
        // phrase in decomposed text, which matches; a word running on past a
        // combining mark, which does not; and pointed Hebrew, which matches.
        LampPresentationDeck(title: "Unicode", slides: [
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "the cafe\u{0301} door", emphasis: [.init(text: "caf\u{00E9}")]),
                .init(kind: .body, text: "grace\u{0301}d", emphasis: [.init(text: "grace")]),
                .init(
                    kind: .body,
                    text: "\u{05D1}\u{05B0}\u{05BC}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05B4}\u{05C1}\u{05D9}\u{05EA} \u{05D1}\u{05B8}\u{05BC}\u{05E8}\u{05B8}\u{05D0}",
                    emphasis: [
                        .init(text: "\u{05D1}\u{05B0}\u{05BC}\u{05E8}\u{05B5}\u{05D0}\u{05E9}\u{05B4}\u{05C1}\u{05D9}\u{05EA}"),
                        .init(text: "\u{05D1}"),
                    ]
                ),
            ]),
        ]),
        // Passages under a title: one drawn as it should be; two sharing a
        // citation, beside a second line the heading has no room for; and a
        // closing slide whose passage crowds it.
        LampPresentationDeck(title: "Epigraph", slides: [
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "Has Mankind Evolved?"),
                .init(kind: .subtitle, text: "A talk"),
                .init(kind: .scripture, text: "But where shall wisdom be found?"),
                .init(kind: .citation, text: "Job 28:12 (ESV)"),
            ]),
            .init(layout: .title, blocks: [
                .init(kind: .title, text: "Title"),
                .init(kind: .subtitle, text: "One line"),
                .init(kind: .body, text: "Another"),
                .init(kind: .scripture, text: "But where shall wisdom be found?"),
                .init(kind: .scripture, text: "Behold, the fear of the Lord, that is wisdom"),
                .init(kind: .citation, text: "Job 28 (ESV)"),
            ]),
            .init(layout: .closing, blocks: [
                .init(kind: .title, text: "Closing"),
                .init(kind: .body, text: "A line under the heading"),
                .init(kind: .scripture, text: String(repeating: "wisdom ", count: 80)),
                .init(kind: .citation, text: "Job 28 (ESV)"),
            ]),
        ]),
        // Charts: every rule the two hold a chart to, the new kinds among
        // them, beside charts of each kind that draw as written.
        LampPresentationDeck(title: "Charts", slides: {
            let one = [LampPresentationChart.Value(label: "One", value: 1)]
            let source = LampPresentationChart.Source(strongs: "G26", translationID: "T")
            func slide(_ chart: LampPresentationChart) -> LampPresentationSlide {
                .init(layout: .image, blocks: [.init(kind: .chart, chart: chart)])
            }
            return [
                // No values yet, and a filter keeping one value of the feature charted.
                slide(.init(
                    source: .init(
                        strongs: "G26", translationID: "T",
                        filter: .init(grammar: .init(feature: .grammaticalCase, value: "Genitive"))
                    ),
                    by: .grammar, feature: .grammaticalCase
                )),
                // The Hebrew and Greek texts let into a chart that is not a
                // comparison, which cannot hold them back or let them in.
                slide(.init(
                    source: .init(
                        strongs: "G26", translationID: "T", includesOriginalLanguages: true
                    ),
                    by: .book, values: one
                )),
                // And asked for where it is read, which says nothing.
                slide(.init(
                    source: .init(
                        strongs: "G26", translationID: "", includesOriginalLanguages: true
                    ),
                    by: .translation, values: one
                )),
                // A feature and a list of translations that a chart by book reads neither of.
                slide(.init(
                    source: .init(strongs: "G26", translationID: "T", translations: ["U"]),
                    by: .book, feature: .tense, values: one
                )),
                // A rate a companion does not read.
                slide(.init(source: source, by: .companion, measure: .perThousandWords, values: one)),
                // A headword only a card draws.
                slide(.init(
                    source: source, by: .book, values: one,
                    headword: .init(occurrences: 1, verses: 1, books: 1, bookCount: 1, perThousandWords: 1, translation: "T")
                )),
                // Figures only a card prints, a figure neither knows, and a
                // fourth figure no card has room for.
                slide(.init(source: source, by: .book, figures: ["verses"], values: one)),
                slide(.init(
                    source: source, by: .book, style: .card,
                    figures: ["verses", "wingspan", "forms", "commonest"], values: one
                )),
                // A ring of nine slices, at a rate.
                slide(.init(
                    source: source, by: .rendering, measure: .perThousandWords, style: .share,
                    values: Array(repeating: one[0], count: 9)
                )),
                // A filter naming nothing, and one keeping the one rendering charted.
                slide(.init(source: .init(strongs: "G26", translationID: "T", filter: .init(form: " ")), by: .book, values: one)),
                slide(.init(source: .init(strongs: "G26", translationID: "T", filter: .init(rendering: "love")), by: .rendering, values: one)),
                // Drawn as written.
                slide(.init(source: source, by: .book, style: .card, values: one)),
                slide(.init(
                    source: source, by: .book, style: .card,
                    figures: ["commonest", "chapters"], values: one
                )),
                slide(.init(source: .init(strongs: "G26", translationID: "", translations: ["T", "U"]), by: .translation, values: one)),
                slide(.init(source: .init(strongs: "G26", translationID: "T", filter: .init(rendering: "love")), by: .section, values: one)),
                slide(.init(source: source, by: .grammar, feature: .tense, style: .share, values: one)),
            ]
        }()),
        // Timelines zoomed and not: too crowded unzoomed, a zoom too wide, a
        // stretch outside the timeline, a stretch backwards, a zoom on a
        // structure, and one well-formed.
        {
            func timeline(_ count: Int, zoom: LampPresentationTimelineZoom?) -> LampPresentationBlock {
                .init(
                    kind: .body,
                    text: (1...count).map { "\($0) AD \u{2014} Event \($0)" }.joined(separator: "\n"),
                    figure: .timeline,
                    zoom: zoom
                )
            }
            var chiasm = timeline(5, zoom: .init())
            chiasm.figure = .chiasm
            return LampPresentationDeck(title: "Zoom", slides: [
                timeline(12, zoom: nil),
                timeline(12, zoom: .init(span: 12)),
                timeline(4, zoom: .init(span: 4)),
                timeline(12, zoom: .init(span: 4, from: 0, through: 13)),
                timeline(12, zoom: .init(span: 4, from: 8, through: 3)),
                timeline(41, zoom: .init()),
                chiasm,
                timeline(20, zoom: .init(span: 5, from: 3, through: 9)),
                // Long, but only four events show at once: not crowded.
                {
                    var long = timeline(24, zoom: .init())
                    long.text = (1...24).map { "\($0) AD \u{2014} The church gathers in a new city" }
                        .joined(separator: "\n")
                    return long
                }(),
            ].map { .init(layout: .titleAndBody, blocks: [.init(kind: .title, text: "When"), $0]) }
            + [
                // Emphasis only in a zoomed timeline, lit throughout, leaves
                // nothing to light last; nor does a slide with none at all.
                {
                    var block = timeline(12, zoom: .init())
                    block.emphasis = [.init(text: "Event 3")]
                    return .init(layout: .titleAndBody, blocks: [block], revealsEmphasis: true)
                }(),
                .init(layout: .titleAndBody, blocks: [.init(kind: .body, text: "Plain.")], revealsEmphasis: true),
            ])
        }(),
        // Maps: places found, one unknown, one shared by two places, one
        // uncertain, too many, options on a list, and a map on a layout
        // that draws none.
        {
            func map(_ lines: [String], route: Bool? = nil) -> LampPresentationBlock {
                .init(kind: .body, text: lines.joined(separator: "\n"), figure: .map, map: .init(route: route))
            }
            var list = LampPresentationBlock(kind: .body, text: "A\nB", map: .init(route: true))
            list.listStyle = .unordered
            return LampPresentationDeck(title: "Maps", slides: [
                .init(layout: .titleAndBody, blocks: [map(["Jerusalem", "Antioch 2 \u{2014} Pisidian Antioch"], route: true)]),
                .init(layout: .titleAndBody, blocks: [map(["Atlantis"])]),
                .init(layout: .titleAndBody, blocks: [map(["Antioch"])]),
                .init(layout: .titleAndBody, blocks: [map(["Gog", "Magog"])]),
                .init(layout: .blank, blocks: [map((1...17).map { _ in "Ephesus" })]),
                .init(layout: .titleAndBody, blocks: [list]),
                .init(layout: .twoColumn, blocks: [map(["Rome"]), .init(kind: .body, text: "Beside")]),
                // A name more than one place goes by, counting other names.
                .init(layout: .titleAndBody, blocks: [map(["Kadesh", "Carmel"])]),
                // Places too close to draw apart.
                .init(layout: .titleAndBody, blocks: [map(["Jerusalem", "Ophel", "Bethany"])]),
                // A map's names are printed plain, so its emphasis lights
                // nothing.
                {
                    var block = map(["Jerusalem", "Bethlehem"])
                    block.emphasis = [.init(text: "Jerusalem")]
                    return .init(layout: .titleAndBody, blocks: [block], revealsEmphasis: true)
                }(),
            ])
        }(),
        // Drift: on pictures behind and beside the words, which is fine,
        // and on a body and a caption, which cannot drift.
        LampPresentationDeck(title: "Drift", slides: [
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Words.", motion: .drift),
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A", placement: .background, motion: .drift),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/b.jpg", altText: "B", motion: .drift),
                .init(kind: .caption, text: "A credit", motion: .drift),
            ]),
        ]),
        // Video: played on a picture, not on words, not in a format Lamp
        // does not play.
        LampPresentationDeck(title: "Video", slides: [
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Words.", video: "Assets/a.mp4"),
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A", placement: .background, video: "Assets/a.mov"),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/b.jpg", altText: "B", video: "Assets/b.webm"),
            ]),
            // A background Lamp cannot play leaves the framed one to play.
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .image, assetPath: "Assets/e.jpg", altText: "E", placement: .background, video: "Assets/e.webm"),
                .init(kind: .image, assetPath: "Assets/f.jpg", altText: "F", video: "Assets/f.mp4"),
            ]),
            // Two videos: the one behind the slide plays, though it comes second.
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .image, assetPath: "Assets/c.jpg", altText: "C", video: "Assets/c.mp4"),
                .init(kind: .image, assetPath: "Assets/d.jpg", altText: "D", placement: .background, video: "Assets/d.mp4"),
            ]),
        ]),
        // Clips: from a file, from YouTube and Vimeo, from a site Lamp does
        // not play, with a bad start, on words, beside a looping video, and
        // two on a slide, where the one behind it plays.
        LampPresentationDeck(title: "Clips", slides: [
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/a.jpg", altText: "A", clip: .init(source: "Assets/a.mp4")),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/b.jpg", altText: "B",
                      clip: .init(source: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", start: 10, end: 20)),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/c.jpg", altText: "C", clip: .init(source: "https://vimeo.com/76979871")),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/d.jpg", altText: "D", clip: .init(source: "https://example.com/talk")),
            ]),
            .init(layout: .image, blocks: [
                .init(kind: .image, assetPath: "Assets/e.jpg", altText: "E", clip: .init(source: "Assets/e.mp4", start: 30, end: 5)),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .body, text: "Words.", clip: .init(source: "Assets/f.mp4")),
                .init(kind: .image, assetPath: "Assets/g.jpg", altText: "G", video: "Assets/g-loop.mp4",
                      clip: .init(source: "Assets/g.mp4")),
            ]),
            .init(layout: .titleAndBody, blocks: [
                .init(kind: .title, text: "Heading"),
                .init(kind: .image, assetPath: "Assets/h.jpg", altText: "H", clip: .init(source: "Assets/h.mp4")),
                .init(kind: .image, assetPath: "Assets/i.jpg", altText: "I", placement: .background,
                      clip: .init(source: "https://youtu.be/dQw4w9WgXcQ")),
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

    /// The deck skill checks map lines against its own copy of the places,
    /// which must be the ones Lamp draws.
    @Test func theSkillsPlacesAreTheOnesLampDraws() throws {
        let copy = scriptURL.deletingLastPathComponent().appendingPathComponent("places.json")
        let shipped = try #require(LampMapPlaces.resourceURL)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: shipped))
    }
}
