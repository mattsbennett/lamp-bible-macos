import Foundation
import LampCore
import LampModuleKit
@testable import LampMCPServer
import MCP
import Testing

/// Real module/tool interactions for the research recipes in the study skills.
/// These test retrieval behaviour, not the presence of particular prompt words.
struct StudyResearchContractTests {
    private struct Fixture {
        let root: URL
        let handler: LampMCPToolHandler
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-research-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        for (id, book, number, testament, words) in [
            ("STUDY_NT", "John", 43, "NT", ["The Word was in the beginning", "The Word was with God", "The Word was God"]),
            ("STUDY_OT", "Genesis", 1, "OT", ["In the beginning"]),
        ] {
            let verses: [[String: Any]] = words.enumerated().map { index, text in
                ["v": index + 1, "ref": number * 1_000_000 + 1_000 + index + 1,
                 "content": ["text": text, "annotations": [
                    ["type": "strongs", "start": 4, "end": 8, "data": ["strongs": "G3056"]],
                 ]]]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "meta": ["schemaVersion": "1.0", "id": id, "type": "translation",
                         "name": id, "abbreviation": id, "language": "en"],
                "books": [["id": book, "name": book, "number": number,
                           "testament": testament, "chapters": [["chapter": 1, "verses": verses]]]],
            ])
            let url = root.appendingPathComponent(id + ".lamp")
            _ = try LampModuleCompiler().compile(
                data: data, sourceFilename: id + ".json", destinationURL: url
            )
            _ = try await library.install(from: url)
        }
        let policy = LampAgentAccessPolicy(maximumSearchResults: 1, maximumPassageVerses: 1)
        return Fixture(root: root, handler: LampMCPToolHandler(
            library: LampAgentLibrary(library: library, policy: policy), policy: policy
        ))
    }

    @Test func keyOnlyAndTextSearchesWorkWithoutDummyArgumentsAndRespectTheCap() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for search: [String: Value] in [
            ["strongs_key": .string("G3056")], ["query": .string("Word")],
        ] {
            let result = try await fixture.handler.call(name: "search_library", arguments: search.merging([
                "kinds": .array([.string("translation")]),
                "module_ids": .array([.string("STUDY_NT")]),
                "limit": .int(50),
            ]) { _, value in value })
            let results = try #require(result.structuredContent?.objectValue?["results"]?.arrayValue)
            #expect(results.count == 1, "a requested limit cannot bypass the reader's cap")
            #expect(results.first?.objectValue?["moduleID"]?.stringValue == "STUDY_NT")
        }
        for arguments: [String: Value] in [[:], ["query": .string(" \n")], ["strongs_key": .string(" ")]] {
            await #expect(throws: LampMCPToolError.self) {
                try await fixture.handler.call(name: "search_library", arguments: arguments)
            }
        }
    }

    @Test func incompatibleCoverageCanBeRetriedWithOnlyTheRelevantModule() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: LampAgentError.bookNotInModule(book: "John", moduleID: "STUDY_OT")) {
            try await fixture.handler.call(name: "read_passage", arguments: [
                "reference": .string("John 1:1"),
                "translation_ids": .array([.string("STUDY_NT"), .string("STUDY_OT")]),
            ])
        }
        let result = try await fixture.handler.call(name: "read_passage", arguments: [
            "reference": .string("John 1:1"),
            "translation_ids": .array([.string("STUDY_NT")]),
        ])
        let passages = try #require(result.structuredContent?.objectValue?["results"]?.arrayValue)
        #expect(passages.count == 1)
        #expect(passages.first?.objectValue?["reference"]?.stringValue == "John 1:1")
    }

    @Test func aTruncatedPassageCanBeCompletedWithSmallerRanges() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (reference, truncated) in [("John 1:1-3", true), ("John 1:2", false), ("John 1:3", false)] {
            let result = try await fixture.handler.call(name: "read_passage", arguments: [
                "reference": .string(reference),
                "translation_ids": .array([.string("STUDY_NT")]),
            ])
            let passage = try #require(result.structuredContent?.objectValue?["results"]?.arrayValue?.first?.objectValue)
            #expect(passage["wasTruncated"]?.boolValue == truncated)
            #expect(passage["verses"]?.arrayValue?.count == 1)
            if !truncated { #expect(passage["reference"]?.stringValue == reference) }
        }
    }
}
