import Foundation
import LampCore
import LampModuleKit
import MCP
@testable import LampMCPServer
import Testing

/// Exercise the tool responses the language skill tells an agent to follow,
/// not a second copy of the instructions or assertions about their wording.
struct StudyLanguageEvidenceTests {
    private func install(_ json: String, id: String, root: URL, library: LampLibrary) async throws {
        let archive = root.appendingPathComponent(id + ".lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: id + ".json", destinationURL: archive
        )
        _ = try await library.install(from: archive)
    }

    private func translation(id: String, tagged: Bool) -> String {
        let annotations = tagged ? #", "annotations":[{"type":"strongs","start":0,"end":5,"data":{"strongs":"G6001"}}]"# : ""
        return """
            {"meta":{"schemaVersion":"1.0","id":"\(id)","type":"translation",
                     "name":"\(id) fixture","abbreviation":"\(id)","language":"el",
                     "features":{"strongs":\(tagged)}},
             "books":[{"id":"Matt","name":"Matthew","number":40,"testament":"NT",
               "chapters":[{"chapter":13,"verses":[{"v":48,
                 "content":{"text":"ἄγγος"\(annotations)}}]}]}]}
            """
    }

    private func rows(
        _ tool: String, _ arguments: [String: Value], handler: LampMCPToolHandler
    ) async throws -> [[String: Value]] {
        let response = try await handler.call(name: tool, arguments: arguments)
        #expect(response.isError != true)
        return try #require(response.structuredContent?.objectValue?["results"]?.arrayValue)
            .map { try #require($0.objectValue) }
    }

    @Test func extendedKeysAndUnnumberedHebrewRemainReachableThroughTheStudyTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-study-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LampLibrary(rootURL: root.appendingPathComponent("Library"))
        try await install(#"""
            {"meta":{"schemaVersion":"2.0","id":"tbesg","type":"dictionary",
                     "name":"Greek fixture","language":"el","keyType":"strongs-greek"},
             "entries":[{"key":"G6001","lemma":"ἄγγος","senses":[{
               "definition":"A fixture definition, not a claim about scripture.",
               "septuagintHebrew":[{"text":"כתב","stem":"pi."},
                                   {"text":"אַהֲבָה","strongs":"H0160"}]}]}]}
            """#, id: "tbesg", root: root, library: library)
        try await install(#"""
            {"meta":{"schemaVersion":"2.0","id":"bdb","type":"dictionary",
                     "name":"Hebrew fixture","language":"he","keyType":"bdb"},
             "entries":[{"key":"BDB1","lemma":"כתב","senses":[{
               "definition":"A fixture Hebrew entry discoverable without a Strong's key."}]}]}
            """#, id: "bdb", root: root, library: library)
        for (id, tagged) in [("TAGGED", true), ("UNTAGGED", false)] {
            try await install(translation(id: id, tagged: tagged), id: id, root: root, library: library)
        }
        let handler = LampMCPToolHandler(
            library: LampAgentLibrary(library: library), applicationSupportURL: nil
        )

        let modules = try await rows("list_modules", [:], handler: handler)
        #expect(modules.first { $0["id"]?.stringValue == "TAGGED" }?["tagsStrongs"]?.boolValue == true)
        #expect(modules.first { $0["id"]?.stringValue == "UNTAGGED" }?["tagsStrongs"]?.boolValue == false)

        let exact = try await rows("lookup_dictionary_keys", [
            "keys": .array([.string("G6001")]), "module_ids": .array([.string("tbesg")]),
        ], handler: handler)
        let sense = try #require(exact.first?["senses"]?.arrayValue?.first?.objectValue)
        let hebrew = try #require(sense["septuagintHebrew"]?.arrayValue)
        #expect(hebrew.first?.objectValue?["text"]?.stringValue == "כתב")
        #expect(hebrew.first?.objectValue?["stem"]?.stringValue == "pi.")
        #expect(hebrew.first?.objectValue?["strongs"] == nil)
        #expect(hebrew.last?.objectValue?["strongs"]?.stringValue == "H160")

        for (query, module, key) in [("כתב", "bdb", "BDB1"), ("ἄγγος", "tbesg", "G6001")] {
            let found = try await rows("search_dictionary", [
                "query": .string(query), "module_ids": .array([.string(module)]),
            ], handler: handler)
            #expect(found.map { $0["key"]?.stringValue } == [key])
        }

        let passage = try await rows("read_passage", [
            "reference": .string("Matthew 13:48"),
            "translation_ids": .array([.string("TAGGED")]), "include_annotations": .bool(true),
        ], handler: handler)
        let verse = try #require(passage.first?["verses"]?.arrayValue?.first?.objectValue)
        #expect(verse["annotations"]?.arrayValue?.first?.objectValue?["strongs"]?.stringValue == "G6001")

        let counted = try await rows("analyze_strongs", [
            "key": .string("G6001"),
            "translation_ids": .array([.string("TAGGED"), .string("UNTAGGED")]),
        ], handler: handler)
        #expect(counted.map { $0["translationID"]?.stringValue } == ["TAGGED"])
        #expect(counted.first?["occurrences"]?.intValue == 1)
    }
}
