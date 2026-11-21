import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// A pass reconciles a writing's documents before it merges their review
/// marks, and the marks of a body kept as a copy depend on it.
///
/// Both sides changing one document leaves this Mac's body under a copy's
/// name and the server's at the document's own. The marks here were made
/// of the words in the body that moved, so the intake moves them with it.
/// That is only right while the record holds this Mac's marks alone: were
/// the server's review merged first, the record would hold the arriving
/// body's marks too, and moving the lot would put another device's marks
/// on this Mac's copy and leave its own body unmarked everywhere. The iOS
/// session's planner has that order, and cannot move the record because
/// of it.
///
/// Nothing in the code says so — the order falls out of one loop over
/// sorted paths, where `Workspaces` happens to sort before
/// `WritingReview`. A rename of either folder, or a loop that grouped by
/// kind, would reverse it and leave a green build.
struct WritingDocumentPassOrderTests {
    @Test func adocumentIsTakenInBeforeItsReviewMarks() throws {
        let folder = LampWritingWorkspaceLayout.directoryName(for: "exhortation-2026-11-21")
        let document = try LampWritingWorkspaceLayout.documentPath(folder: folder, name: "outline.md")
        let review = try LampSyncFolderLayout.writingReviewPath(
            writingID: "exhortation-2026-11-21", document: "outline.md"
        )
        #expect(LampSyncFolderLayout.kind(of: document) == .writingDocument)
        #expect(LampSyncFolderLayout.kind(of: review) == .writingReview)
        #expect(
            [document, review].sorted() == [document, review],
            """
            A pass installs what it downloaded in path order, and this one now \
            takes \(review) before \(document). The intake moves a kept copy's \
            marks with the body that moved, which is only right while the record \
            holds this device's marks alone — see `takeInDocument`. Either keep \
            the order, or move the marks somewhere that does not depend on it.
            """
        )
    }

    /// And the writing's own prose record sorts with the documents' rather
    /// than between a document and its marks, so one writing's files are
    /// never interleaved with another's in a way that breaks the rule.
    @Test func awritingsOwnRecordIsTakenInAfterItsDocumentsToo() throws {
        let folder = LampWritingWorkspaceLayout.directoryName(for: "w")
        let document = try LampWritingWorkspaceLayout.documentPath(folder: folder, name: "outline.md")
        let prose = try LampSyncFolderLayout.writingReviewPath(writingID: "w")
        #expect([document, prose].sorted() == [document, prose])
    }
}
