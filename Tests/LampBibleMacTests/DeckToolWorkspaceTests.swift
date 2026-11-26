import AppKit
import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// The deck tools, asked from a writing's workspace, look for the deck's
/// files beside it there, as Lamp will when it imports the deck. Given only
/// the deck's text, they drew every picture as a placeholder and called every
/// file missing, in any writing an agent worked in.
@MainActor
struct DeckToolWorkspaceTests {
    /// A title slide over a looping video, and a slide that plays a clip:
    /// the deck an agent built and validated in an end-to-end run.
    private let deck = Data("""
    {
      "schemaVersion": 1, "id": "aee0282a-e697-424f-90bc-fd286e5236bc", "title": "Into the Wilderness",
      "source": { "kind": "writing", "id": "60910124-99b3-48ca-9310-11c63ed118c1" },
      "aspectRatio": "widescreen", "transition": "dissolve",
      "theme": { "id": "vespers", "backgroundColor": "#241318", "foregroundColor": "#F7EEE9",
                 "accentColor": "#E39B5C", "headingTypeface": "system-serif", "typeface": "system-sans" },
      "slides": [
        { "id": "2a68bbe7-e18d-4be1-acbf-5203dff11baa", "layout": "title", "isHidden": false,
          "speakerNotes": "Let the dawn loop run while people settle.",
          "blocks": [
            { "id": "49c06f71-9e70-41d4-bc74-f62cae4f39a6", "kind": "image", "text": "",
              "assetPath": "Assets/dawn.jpg", "video": "Assets/dawn.mp4",
              "altText": "Dawn over sand dunes", "placement": "background" },
            { "id": "2f1393d2-cb12-4aeb-a550-292a368079dc", "kind": "title", "text": "Into the Wilderness" } ] },
        { "id": "a8b0896b-ad86-44cb-83d7-80d43a07c25b", "layout": "image", "isHidden": false,
          "speakerNotes": "Click to play.",
          "blocks": [
            { "id": "4c78c951-4503-4f89-8247-b198b7c222c7", "kind": "title", "text": "The scroll opens" },
            { "id": "3c28738b-d7b3-437c-96f9-28bc43fa9cb0", "kind": "image", "text": "",
              "assetPath": "Assets/scroll.jpg", "altText": "A scroll unrolling",
              "clip": { "source": "Assets/scroll.mp4", "starts": "click" } } ] }
      ]
    }
    """.utf8)

    /// A workspace holding the deck's four files, less `leaving`.
    private func workspace(leaving: Set<String> = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        let picture = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let jpeg = try #require(picture.representation(using: .jpeg, properties: [:]))
        for name in ["dawn.jpg", "scroll.jpg"] where !leaving.contains(name) {
            try jpeg.write(to: root.appendingPathComponent("Assets/\(name)"))
        }
        for name in ["dawn.mp4", "scroll.mp4"] where !leaving.contains(name) {
            try Data("video".utf8).write(to: root.appendingPathComponent("Assets/\(name)"))
        }
        return root
    }

    private func missing(_ report: LampDeckTools.ValidationReport) -> [String] {
        report.issues.filter { $0.message.hasPrefix("No file at") }.map(\.path)
    }

    @Test func validatingInAWorkspaceLooksForTheDecksFilesThere() throws {
        let complete = try workspace()
        defer { try? FileManager.default.removeItem(at: complete) }
        #expect(missing(LampDeckTools.validate(deckJSON: deck, workspace: complete)) == [])

        let short = try workspace(leaving: ["scroll.mp4", "dawn.jpg"])
        defer { try? FileManager.default.removeItem(at: short) }
        #expect(Set(missing(LampDeckTools.validate(deckJSON: deck, workspace: short)))
            == ["slides[1].blocks[1].clip", "slides[0].blocks[0].assetPath"])
    }

    @Test func aFileReachedThroughALinkCountsAsMissing() throws {
        let root = try workspace(leaving: ["dawn.mp4"])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("video".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Assets/dawn.mp4"), withDestinationURL: outside)
        #expect(missing(LampDeckTools.validate(deckJSON: deck, workspace: root)) == ["slides[0].blocks[0].video"])
    }

    @Test func drawingInAWorkspaceFindsTheDecksFilesAndOnlyAMissingOneIsASlidesProblem() async throws {
        let complete = try workspace()
        defer { try? FileManager.default.removeItem(at: complete) }
        let drawn = try await LampDeckTools.render(
            deckJSON: deck, manuscript: nil, libraryRoot: nil, slideNumbers: nil, width: 640, workspace: complete
        )
        let report = try #require(String(data: drawn.reportJSON, encoding: .utf8))
        #expect(!report.contains("No file at"), "\(report)")

        let short = try workspace(leaving: ["scroll.jpg"])
        defer { try? FileManager.default.removeItem(at: short) }
        let missingOne = try await LampDeckTools.render(
            deckJSON: deck, manuscript: nil, libraryRoot: nil, slideNumbers: nil, width: 640, workspace: short
        )
        let parsed = try #require(try JSONSerialization.jsonObject(with: missingOne.reportJSON) as? [String: Any])
        #expect(parsed["slidesWithProblems"] as? [Int] == [2])
        let slides = try #require(parsed["slides"] as? [[String: Any]])
        let notes = slides.compactMap { $0["notes"] as? [String] }
        #expect(notes[1].contains("No file at 'Assets/scroll.jpg', so a placeholder was drawn in its place."))
        #expect(!notes[0].contains { $0.hasPrefix("No file at") })
    }

    @Test func aFileNamedAsTheDrawingsFolderIsDrawnNotInTheWay() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // The pictures are drawn into a folder called `preview`; a deck may
        // name a picture of that very name.
        try FileManager.default.copyItem(at: root.appendingPathComponent("Assets/dawn.jpg"), to: root.appendingPathComponent("preview"))
        let named = String(decoding: deck, as: UTF8.self).replacingOccurrences(of: "Assets/scroll.jpg", with: "preview")
        let drawn = try await LampDeckTools.render(
            deckJSON: Data(named.utf8), manuscript: nil, libraryRoot: nil, slideNumbers: nil, width: 640, workspace: root
        )
        #expect(drawn.images.count == 2)
        #expect(!String(decoding: drawn.reportJSON, as: UTF8.self).contains("No file at"))
    }
}
