import Foundation
import LampCore
import Testing

/// The import skill's format reference, run through the importer it describes.
///
/// The skill tells an agent to fill every field a source answers, and the
/// reference tells it how to write each one. Both are prose, and prose about a
/// parser rots the moment the parser moves — silently, because a field written
/// in a form Lamp no longer reads is not an error: the writing imports without
/// it, and the person sees a gap they cannot account for.
///
/// Writing the reference for this change, two of its claims were wrong until
/// they were run: a flat `series: "Name"` is discarded by the front matter
/// parser rather than read as the name, and `keyScriptures` takes `sv`/`ev`
/// verse numbers, which the reference had never mentioned. Neither would have
/// been found by reading.
struct ImportSkillFormatTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func reference() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LampBibleMacSupport/Resources/AgentSkills/import-lamp-writing"
            )
        return try String(contentsOf: url.appendingPathComponent("references/format.md"), encoding: .utf8)
    }

    /// A file using every field the reference documents, in the forms it
    /// documents, arrives with every one of them filled and nothing warned
    /// about.
    @Test func afileWritingEveryDocumentedFieldImportsWithEveryFieldFilled() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
            ---
            id: "exhortation-2026-01-18-days-of-noah"
            title: "The Days of Noah"
            subtitle: "Two lessons on readiness"
            author: "Matthew Bennett"
            date: "2026-01-18"
            category: "Bible class"
            tags: ["Matthew", "readiness"]
            series:
              name: "Parables of the Kingdom"
              order: 3
            keyScriptures:
              - ref: "Matthew 24:36-44"
              - ref: "Psalm 23"
              - ref: "The flood narrative"
                sv: 1006001
                ev: 1009017
            summary: "Jesus draws two lessons from the days of Noah."
            created: "2026-01-10T09:00:00Z"
            lastModified: "2026-01-18T11:30:00Z"
            source: "pages-export"
            ---

            For this morning's exhortation, some thoughts from
            [Matthew 24](lampbible://verse/40024001/40024051).
            """.write(
                to: folder.appendingPathComponent("days-of-noah.md"),
                atomically: true, encoding: .utf8
            )

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: folder))
        let item = try #require(plan.items.first)
        #expect(item.action == .create)
        #expect(item.errors.isEmpty)
        #expect(
            item.warnings.isEmpty,
            """
            The reference documents a form the importer does not take: \
            \(item.warnings.joined(separator: " / "))
            """
        )
        try await library.applyWritingImport(plan, selecting: [item.id])

        let writing = try #require(
            await library.personalDevotional(id: "exhortation-2026-01-18-days-of-noah")
        )
        #expect(writing.title == "The Days of Noah")
        #expect(writing.subtitle == "Two lessons on readiness")
        #expect(writing.author == "Matthew Bennett")
        #expect(writing.date == "2026-01-18")
        #expect(writing.tags == ["Matthew", "readiness"])
        // An open vocabulary: the person's own word, with their capitals.
        #expect(writing.category == "Bible class")
        #expect(writing.seriesName == "Parables of the Kingdom")
        #expect(writing.seriesOrder == 3)
        #expect(writing.summary == "Jesus draws two lessons from the days of Noah.")
        let iso = ISO8601DateFormatter()
        #expect(writing.created == iso.date(from: "2026-01-10T09:00:00Z"))
        #expect(writing.lastModified == iso.date(from: "2026-01-18T11:30:00Z"))

        let references = writing.keyScriptures.map { ($0.text, $0.startReference, $0.endReference) }
        #expect(references.count == 3)
        #expect(references[0].1 == 40_024_036)
        #expect(references[0].2 == 40_024_044)
        // A whole chapter runs from its first verse to its last.
        #expect(references[1].1 == 19_023_001)
        #expect(references[1].2 == 19_023_006)
        // Verses given as numbers: the reference Lamp cannot parse is the label.
        #expect(references[2].0 == "The flood narrative")
        #expect(references[2].1 == 1_006_001)
        #expect(references[2].2 == 1_009_017)
    }

    /// `sermon` is filed as `exhortation`, as the reference says, and the
    /// report says it happened.
    @Test func asermonIsFiledAsTheExhortationTheReferenceSaysItBecomes() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("talk.md")
        try "---\ntitle: \"Talk\"\ncategory: \"Sermon\"\n---\n\nText.".write(
            to: file, atomically: true, encoding: .utf8
        )

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        let item = try #require(plan.items.first)
        #expect(item.normalized.contains { $0.contains("exhortation") })
        try await library.applyWritingImport(plan, selecting: [item.id])
        let writing = try #require(await library.personalDevotional(id: item.writingID))
        #expect(writing.category == "exhortation")

        #expect(try reference().contains("`sermon` is filed as `exhortation`"))
    }

    /// Tags written as one comma-separated line, which the reference offers as
    /// an alternative to the list.
    @Test func tagsOnOneLineAreReadAsTheReferenceSaysTheyAre() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("talk.md")
        try "---\ntitle: \"Talk\"\ntags: Matthew, readiness\n---\n\nText.".write(
            to: file, atomically: true, encoding: .utf8
        )

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        let item = try #require(plan.items.first)
        #expect(item.warnings.isEmpty)
        try await library.applyWritingImport(plan, selecting: [item.id])
        let writing = try #require(await library.personalDevotional(id: item.writingID))
        #expect(writing.tags == ["Matthew", "readiness"])
    }

    /// A series written on the `series:` line itself is dropped, which is the
    /// trap the reference now warns about: `series` is a known key, so nothing
    /// is reported, and the writing simply arrives with no series at all.
    @Test func aseriesWrittenFlatIsDroppedAsTheReferenceWarns() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("talk.md")
        try "---\ntitle: \"Talk\"\nseries: \"Parables of the Kingdom\"\n---\n\nText.".write(
            to: file, atomically: true, encoding: .utf8
        )

        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        let plan = try await library.planWritingImport(LampWritingImport.files(at: file))
        let item = try #require(plan.items.first)
        #expect(item.warnings.isEmpty, "the drop is silent, which is why it is written down")
        try await library.applyWritingImport(plan, selecting: [item.id])
        let writing = try #require(await library.personalDevotional(id: item.writingID))
        #expect(writing.seriesName == nil)

        #expect(try reference().contains("a value written on the `series:` line itself is dropped"))
    }

    /// The skill's field table names every field the reference documents, so
    /// an agent told to "fill every field" is told about all of them.
    @Test func theskillsFieldTableNamesEveryFieldTheReferenceDocuments() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/LampBibleMacSupport/Resources/AgentSkills/import-lamp-writing/SKILL.md"
            )
        let skill = try String(contentsOf: url, encoding: .utf8)
        // `source` is accepted and ignored, so it is nothing for an agent to
        // fill; every other documented field is one.
        for field in [
            "id", "title", "subtitle", "author", "date", "category", "tags",
            "series", "keyScriptures", "summary", "created", "lastModified",
        ] {
            #expect(
                skill.contains("`\(field)`"),
                "\(field) is documented in the format reference and never named in the skill"
            )
        }
    }
}
