import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

struct PresentationDeckSyncTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-deck-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func library(_ name: String, in root: URL) throws -> URL {
        let library = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return library
    }

    @discardableResult
    private func save(_ deck: LampPresentationDeck, in library: URL, at offset: TimeInterval) throws -> URL {
        let url = try LampPresentationDeckStore(rootURL: library).save(deck)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func titles(in library: URL) throws -> [String] {
        try LampPresentationDeckStore(rootURL: library).decks().map(\.title)
    }

    /// Publishes one Mac's library and pulls it into another's, through a real
    /// sync archive, as a sync does.
    private func sync(from source: URL, to destination: URL, in root: URL) throws {
        let outgoing = root.appendingPathComponent("outgoing-\(UUID().uuidString)", isDirectory: true)
        try LampWorkspaceSync.exportPortableWorkspaces(from: source, to: outgoing, installID: "mac")
        let archive = try LampSyncArchive.decode(
            compressedData: LampSyncArchive.create(from: outgoing).compressedData()
        )
        let incoming = root.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        try archive.extract(to: incoming)
        try LampWorkspaceSync.importPortableWorkspaces(from: incoming, into: destination)
    }

    @Test func aDeckBuiltOnOneMacAppearsOnTheOther() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        let deck = LampPresentationDeck.starter(title: "Psalm 23")
        try save(deck, in: macA, at: 0)

        try sync(from: macA, to: macB, in: root)

        #expect(try LampPresentationDeckStore(rootURL: macB).deck(id: deck.id) == deck)
    }

    @Test func theMostRecentlySavedCopyWins() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        var deck = LampPresentationDeck.starter(title: "Draft")
        try save(deck, in: macA, at: 0)
        try sync(from: macA, to: macB, in: root)

        deck.title = "Edited on Mac B"
        try save(deck, in: macB, at: 60)
        deck.title = "Older edit on Mac A"
        try save(deck, in: macA, at: 30)

        try sync(from: macA, to: macB, in: root)
        #expect(try titles(in: macB) == ["Edited on Mac B"])
        try sync(from: macB, to: macA, in: root)
        #expect(try titles(in: macA) == ["Edited on Mac B"])
    }

    @Test func aDeletionReachesTheOtherMac() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        let kept = LampPresentationDeck.starter(title: "Kept")
        let removed = LampPresentationDeck.starter(title: "Removed")
        try save(kept, in: macA, at: 0)
        try save(removed, in: macA, at: 0)
        try sync(from: macA, to: macB, in: root)
        #expect(try titles(in: macB) == ["Kept", "Removed"])

        try LampPresentationDeckSync.recordDeletion(of: removed.id, in: macA, at: base.addingTimeInterval(10))
        try LampPresentationDeckStore(rootURL: macA).delete(id: removed.id)
        try sync(from: macA, to: macB, in: root)

        #expect(try titles(in: macB) == ["Kept"])
    }

    @Test func anOlderCopyCannotBringADeletedDeckBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        let deck = LampPresentationDeck.starter(title: "Removed")
        try save(deck, in: macA, at: 0)
        try sync(from: macA, to: macB, in: root)

        // Deleted on Mac A, then Mac B — which still has it — publishes first.
        try LampPresentationDeckSync.recordDeletion(of: deck.id, in: macA, at: base.addingTimeInterval(10))
        try LampPresentationDeckStore(rootURL: macA).delete(id: deck.id)
        try sync(from: macB, to: macA, in: root)

        #expect(try titles(in: macA).isEmpty)
    }

    @Test func aDeckEditedAfterItsDeletionIsKept() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        var deck = LampPresentationDeck.starter(title: "Draft")
        try save(deck, in: macA, at: 0)
        try sync(from: macA, to: macB, in: root)

        try LampPresentationDeckSync.recordDeletion(of: deck.id, in: macA, at: base.addingTimeInterval(10))
        try LampPresentationDeckStore(rootURL: macA).delete(id: deck.id)
        deck.title = "Still wanted"
        try save(deck, in: macB, at: 20)

        try sync(from: macA, to: macB, in: root)
        #expect(try titles(in: macB) == ["Still wanted"])
        try sync(from: macB, to: macA, in: root)
        #expect(try titles(in: macA) == ["Still wanted"])
    }

    @Test func deletionsAreRememberedAcrossLaterSyncs() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root), macB = try library("Mac B", in: root)
        let macC = try library("Mac C", in: root)
        let deck = LampPresentationDeck.starter(title: "Removed")
        try save(deck, in: macA, at: 0)
        try sync(from: macA, to: macC, in: root)

        try LampPresentationDeckSync.recordDeletion(of: deck.id, in: macA, at: base.addingTimeInterval(10))
        try LampPresentationDeckStore(rootURL: macA).delete(id: deck.id)
        // Mac B learns of the deletion, then passes it on to Mac C.
        try sync(from: macA, to: macB, in: root)
        try sync(from: macB, to: macC, in: root)

        #expect(try titles(in: macC).isEmpty)
    }

    @Test func unreadableOrMisplacedDecksAreLeftOut() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try library("Mac A", in: root)
        let decks = LampPresentationDeckStore(rootURL: macA).decksDirectoryURL
        try FileManager.default.createDirectory(at: decks, withIntermediateDirectories: true)
        try Data("not a deck".utf8).write(to: decks.appendingPathComponent("broken.lampdeck"))
        try save(LampPresentationDeck.starter(title: "Good"), in: macA, at: 0)

        let outgoing = root.appendingPathComponent("outgoing", isDirectory: true)
        try LampWorkspaceSync.exportPortableWorkspaces(from: macA, to: outgoing, installID: "mac")
        let paths = try LampSyncArchive.create(from: outgoing).entries.map(\.path)

        #expect(paths.filter { $0.hasSuffix(".lampdeck") }.count == 1)
        #expect(!paths.contains { $0.hasSuffix("broken.lampdeck") })
    }

    @Test func importedDecksStayInsideTheLibrary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let macB = try library("Mac B", in: root)
        let incoming = root.appendingPathComponent("incoming/Workspaces/Presentations", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let deck = LampPresentationDeck.starter(title: "Linked")
        let data = try LampPresentationDeckStore(rootURL: macB).encoded(deck)
        // A link standing in for a deck must not be followed out of the backup.
        let outside = root.appendingPathComponent("outside.lampdeck")
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: incoming.appendingPathComponent("linked.lampdeck"),
            withDestinationURL: outside
        )

        try LampPresentationDeckSync.importDecks(from: root.appendingPathComponent("incoming"), into: macB)

        #expect(try titles(in: macB).isEmpty)
    }
}

struct PresentationAssetSyncTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-asset-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func deck(named title: String, usingAsset name: String?) -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: title)
        if let name {
            deck.slides.append(
                LampPresentationSlide(
                    layout: .image,
                    blocks: [
                        LampPresentationBlock(
                            kind: .image,
                            assetPath: "\(LampPresentationDeckStore.assetsDirectoryName)/\(name)",
                            altText: "A picture"
                        ),
                    ]
                )
            )
        }
        return deck
    }

    @discardableResult
    private func writeAsset(
        _ name: String,
        _ contents: String,
        in library: URL,
        at offset: TimeInterval = 0
    ) throws -> URL {
        let directory = LampPresentationDeckStore(rootURL: library).assetsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func assetContents(_ name: String, in library: URL) -> String? {
        let url = LampPresentationDeckStore(rootURL: library).assetsDirectoryURL
            .appendingPathComponent(name)
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("An image reaches the other Mac with its deck")
    func assetsTravelWithDecks() throws {
        let macA = try makeLibrary()
        let macB = try makeLibrary()
        let backup = try makeLibrary()

        let deck = deck(named: "Pictures", usingAsset: "photo.jpg")
        try LampPresentationDeckStore(rootURL: macA).save(deck)
        try writeAsset("photo.jpg", "first", in: macA)

        try LampPresentationDeckSync.exportDecks(from: macA, to: backup)
        try LampPresentationDeckSync.importDecks(from: backup, into: macB)

        #expect(assetContents("photo.jpg", in: macB) == "first")
    }

    @Test("The most recently saved copy of an image wins")
    func newestImageWins() throws {
        let macA = try makeLibrary()
        let macB = try makeLibrary()
        let backup = try makeLibrary()

        let deck = deck(named: "Pictures", usingAsset: "photo.jpg")
        try LampPresentationDeckStore(rootURL: macA).save(deck)
        try LampPresentationDeckStore(rootURL: macB).save(deck)
        try writeAsset("photo.jpg", "newer", in: macA, at: 500)
        try writeAsset("photo.jpg", "older", in: macB, at: 100)

        try LampPresentationDeckSync.exportDecks(from: macA, to: backup)
        try LampPresentationDeckSync.importDecks(from: backup, into: macB)

        #expect(assetContents("photo.jpg", in: macB) == "newer")
    }

    @Test("An older incoming image does not overwrite a newer local one")
    func olderImageIsRefused() throws {
        let macA = try makeLibrary()
        let macB = try makeLibrary()
        let backup = try makeLibrary()

        let deck = deck(named: "Pictures", usingAsset: "photo.jpg")
        try LampPresentationDeckStore(rootURL: macA).save(deck)
        try LampPresentationDeckStore(rootURL: macB).save(deck)
        try writeAsset("photo.jpg", "older", in: macA, at: 100)
        try writeAsset("photo.jpg", "newer", in: macB, at: 500)

        try LampPresentationDeckSync.exportDecks(from: macA, to: backup)
        try LampPresentationDeckSync.importDecks(from: backup, into: macB)

        #expect(assetContents("photo.jpg", in: macB) == "newer")
    }

    @Test("Sync never deletes an image, so a deck in flight cannot lose its picture")
    func syncDoesNotDeleteAssets() throws {
        let macA = try makeLibrary()
        let macB = try makeLibrary()
        let backup = try makeLibrary()

        try LampPresentationDeckStore(rootURL: macA).save(deck(named: "Empty", usingAsset: nil))
        try writeAsset("kept.jpg", "still here", in: macB)

        try LampPresentationDeckSync.exportDecks(from: macA, to: backup)
        try LampPresentationDeckSync.importDecks(from: backup, into: macB)

        #expect(assetContents("kept.jpg", in: macB) == "still here")
    }

    @Test("Pruning removes only images no deck references")
    func pruneKeepsReferencedAssets() throws {
        let library = try makeLibrary()
        try LampPresentationDeckStore(rootURL: library).save(deck(named: "Used", usingAsset: "used.jpg"))
        try writeAsset("used.jpg", "keep", in: library)
        try writeAsset("orphan.jpg", "drop", in: library)

        try LampPresentationDeckSync.pruneUnreferencedAssets(in: library)

        #expect(assetContents("used.jpg", in: library) == "keep")
        #expect(assetContents("orphan.jpg", in: library) == nil)
    }

    @Test("An image shared by two decks survives deleting one of them")
    func pruneKeepsSharedAssets() throws {
        let library = try makeLibrary()
        let store = LampPresentationDeckStore(rootURL: library)
        try store.save(deck(named: "First", usingAsset: "shared.jpg"))
        var second = deck(named: "Second", usingAsset: "shared.jpg")
        second.id = "second-deck"
        try store.save(second)
        try writeAsset("shared.jpg", "keep", in: library)

        try store.delete(id: second.id)
        try LampPresentationDeckSync.pruneUnreferencedAssets(in: library)

        #expect(assetContents("shared.jpg", in: library) == "keep")
    }
}
