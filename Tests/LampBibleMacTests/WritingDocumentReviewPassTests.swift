import Foundation
import LampBibleMacSupport
import LampCore
import LampModuleKit
import Testing

/// A document's review marks crossing between two devices, through the
/// Mac's own pass rather than core's rules alone.
///
/// Every claim this feature makes about sync rests on these three: a
/// record reaching the other device as that document's, a record of
/// another document being refused rather than merged, and a record
/// going when its document goes. All three were wrong at some point in
/// a way core's own tests could not see, because what was wrong was the
/// pass's wiring — the path it read the writing from, the path it sent
/// the bytes under, the document it told the store about.
struct WritingDocumentReviewPassTests {
    private let writingID = "exhortation-2026-11-21"
    private let document = "outline.md"

    private func makeLibrary() throws -> (library: LampLibrary, root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-review-pass-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (LampLibrary(rootURL: root), root, workspace)
    }

    private func passLibrary(_ library: LampLibrary, workspace: URL) -> LampSyncMacPassLibrary {
        LampSyncMacPassLibrary(library: library, workspace: workspace) { _ in Data() }
    }

    /// A marked document, as one device would hold it.
    private func marked(
        in root: URL, old: String = "One. The flood came.",
        new: String = "One. The flood came suddenly."
    ) throws -> (record: LampWritingReview, path: String, file: URL) {
        let store = LampWritingReviewStore(rootURL: root)
        let record = LampWritingReview(writingID: writingID, document: document)
            .markingAssistantChange(from: old, to: new)
        try store.save(record)
        let path = try LampSyncFolderLayout.writingReviewPath(
            writingID: writingID, document: document
        )
        return (record, path, root.appendingPathComponent(path))
    }

    /// One device's record reaches the other as that document's, and not
    /// as the writing's own. The pass took the writing from the path and
    /// nothing else once, so a document's marks were merged into the
    /// prose — and the prose's bytes were sent back under the document's
    /// name, which every other device then rightly refused.
    @Test func adocumentsRecordCrossesAsThatDocuments() async throws {
        let (theirs, theirRoot, _) = try makeLibrary()
        let (ours, ourRoot, workspace) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: theirRoot)
            try? FileManager.default.removeItem(at: ourRoot)
        }
        _ = theirs
        let sent = try marked(in: theirRoot)

        try await passLibrary(ours, workspace: workspace).install(sent.path, from: sent.file)

        let here = LampWritingReviewStore(rootURL: ourRoot)
        #expect(try here.review(writingID: writingID, document: document).marks.count == 1)
        // And nothing landed in the writing's own record.
        #expect(try here.review(writingID: writingID).marks.isEmpty)
        #expect(try here.reviewed().map(\.documentKey) == ["outline_2Emd"])
    }

    /// A record that says it is another document's is refused rather
    /// than merged. Nothing in the merge compares identity, so a file
    /// that reached the wrong name would take its marks into the
    /// document that name belongs to — marks made of words that
    /// document does not contain.
    @Test func arecordOfAnotherDocumentIsRefusedByThePass() async throws {
        let (theirs, theirRoot, _) = try makeLibrary()
        let (ours, ourRoot, workspace) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: theirRoot)
            try? FileManager.default.removeItem(at: ourRoot)
        }
        _ = theirs
        let sent = try marked(in: theirRoot)
        // The same bytes, arriving at another document's name.
        let wrong = try LampSyncFolderLayout.writingReviewPath(
            writingID: writingID, document: "notes.md"
        )
        let misplaced = theirRoot.appendingPathComponent(wrong)
        try FileManager.default.createDirectory(
            at: misplaced.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sent.file, to: misplaced)

        await #expect(throws: (any Error).self) {
            try await passLibrary(ours, workspace: workspace).install(wrong, from: misplaced)
        }
        #expect(try LampWritingReviewStore(rootURL: ourRoot).reviewed().isEmpty)
    }

    /// A deletion carried out for a document's record takes that record
    /// and no other. It named only the writing once, so deleting an
    /// outline's marks deleted every mark in the writing.
    @Test func adeletionTakesTheDocumentsRecordAndNotTheWritings() async throws {
        let (library, root, workspace) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        _ = try marked(in: root)
        try store.save(
            LampWritingReview(writingID: writingID)
                .markingAssistantChange(from: "Prose.", to: "Prose, changed.")
        )
        #expect(try store.reviewed().count == 2)

        let path = try LampSyncFolderLayout.writingReviewPath(
            writingID: writingID, document: document
        )
        try await passLibrary(library, workspace: workspace).deleteLocally(path)

        // The document's record is gone and the writing's is untouched.
        #expect(try store.reviewed().map(\.documentKey) == [nil])
        #expect(try store.review(writingID: writingID).marks.count == 1)
    }
}
