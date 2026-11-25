import Foundation
import LampCore
import LampModuleKit
@testable import LampBibleMacSupport
import Testing

/// A media file whose owner the library no longer has is still a file the
/// library holds, and the gather has to say so.
///
/// `../../lamp-bible-core/Documentation/ScalabilityPlan.md`, the faults the
/// unclaimed-install reports turned up once they were audible. Nothing lists
/// media, so `LampSyncFilePlan.change`'s media branch downloads any media
/// member with no local copy **unconditionally** — then `install` writes it
/// where it already was, and the next pass does it again. Five pictures on
/// the owner's library were doing that, for a writing the deletion ledger
/// records neither as present nor as deleted.
struct OrphanedMediaIsHeldTests {
    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-orphan-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeMedia(
        in library: URL, scope: LampMediaScope, owner: String, named name: String
    ) throws -> URL {
        let directory = library
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(scope.folder, isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("a picture".utf8).write(to: url)
        return url
    }

    /// The shape measured on the real library: no writings at all, and five
    /// pictures left behind under one writing's id.
    @Test func claimsApictureWhoseWritingTheLibraryNoLongerHas() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = "DAE17410-9918-4F80-8143-94211250BEE9"
        for name in ["one.jpg", "two.jpg"] {
            _ = try writeMedia(in: root, scope: .devotional, owner: orphan, named: name)
        }

        let gathered = LampSyncLocalFiles.devotionalMedia(
            for: [], remoteModuleID: "writing", inLibraryAt: root,
            members: [
                "WritingMedia/writing/\(orphan)/one.jpg",
                "WritingMedia/writing/\(orphan)/two.jpg",
            ]
        )

        #expect(gathered.candidates.map(\.path).sorted() == [
            "WritingMedia/writing/\(orphan)/one.jpg",
            "WritingMedia/writing/\(orphan)/two.jpg",
        ])
        #expect(gathered.candidates.allSatisfy { $0.kind == .devotionalMedia })
        #expect(gathered.missing.isEmpty)
    }

    /// A note's picture whose note is gone, the same way: one hole, both
    /// scopes.
    @Test func claimsAnotePictureWhoseNoteTheLibraryNoLongerHas() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeMedia(in: root, scope: .note, owner: "14007001", named: "tomb.png")

        let gathered = LampSyncLocalFiles.noteMedia(
            for: [], remoteModuleID: "personal-notes", inLibraryAt: root,
            members: ["NoteMedia/personal-notes/14007001/tomb.png"]
        )

        #expect(gathered.candidates.map(\.path) == ["NoteMedia/personal-notes/14007001/tomb.png"])
        #expect(gathered.candidates.allSatisfy { $0.kind == .noteMedia })
    }

    /// A file an owner refers to keeps the candidate the owner produced, so
    /// nothing is claimed twice and the owner's own error reporting is
    /// unchanged.
    @Test func doesNotClaimApictureTwice() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = LampDevotionalMediaReference(
            id: "ref-held", type: .image, filename: "held.jpg", mimeType: "image/jpeg"
        )
        let writing = LampDevotional(
            id: "W1",
            moduleID: "personal-devotionals",
            moduleName: "Writing",
            title: "A lamp",
            content: "Light on the water.",
            mediaJSON: String(decoding: try JSONEncoder().encode([reference]), as: UTF8.self)
        )
        _ = try writeMedia(in: root, scope: .devotional, owner: "W1", named: "held.jpg")

        let gathered = LampSyncLocalFiles.devotionalMedia(
            for: [writing], remoteModuleID: "writing", inLibraryAt: root,
            members: ["WritingMedia/writing/W1/held.jpg"]
        )

        #expect(gathered.candidates.map(\.path) == ["WritingMedia/writing/W1/held.jpg"])
    }

    /// A link is not published, as `decisions/0010` has it: a pass publishes
    /// only an ordinary file.
    @Test func doesNotClaimAlink() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try writeMedia(in: root, scope: .devotional, owner: "W1", named: "real.jpg")
        let link = real.deletingLastPathComponent().appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let gathered = LampSyncLocalFiles.devotionalMedia(
            for: [], remoteModuleID: "writing", inLibraryAt: root,
            members: [
                "WritingMedia/writing/W1/real.jpg", "WritingMedia/writing/W1/link.jpg",
            ]
        )

        #expect(gathered.candidates.map(\.path) == ["WritingMedia/writing/W1/real.jpg"])
    }

    /// A picture the manifest does not name is **not** claimed, because a
    /// candidate at an unnamed path is *uploaded*.
    ///
    /// Deleting a writing leaves its attachments on disk. If it was deleted
    /// before its first sync, nothing on the server names them — and
    /// volunteering them here would publish pictures the reader deleted. A
    /// reviewer caught this: disk discovery may only answer "that member is
    /// here".
    @Test func doesNotVolunteerApictureNobodyNames() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeMedia(in: root, scope: .devotional, owner: "W-never-synced", named: "gone.jpg")

        let gathered = LampSyncLocalFiles.devotionalMedia(
            for: [], remoteModuleID: "writing", inLibraryAt: root,
            members: ["WritingMedia/writing/W-other/kept.jpg"]
        )

        #expect(gathered.candidates.isEmpty)
    }

    /// A notes *module*'s pictures live under `Media/Notes/module-<id>/` and
    /// are gathered elsewhere under their own member paths, so the scan must
    /// not invent a verse-owner path for them. The member list is what keeps
    /// them out.
    @Test func doesNotClaimAnotesModulesPicturesAsAverseOwners() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeMedia(in: root, scope: .note, owner: "module-nic", named: "plate.png")

        let gathered = LampSyncLocalFiles.noteMedia(
            for: [], remoteModuleID: "personal-notes", inLibraryAt: root,
            members: ["NoteMedia/personal-notes/14007001/tomb.png"]
        )

        #expect(gathered.candidates.isEmpty)
    }

    /// A library with no `Media` folder at all answers nothing, rather than
    /// failing.
    @Test func answersNothingWithNoMediaFolder() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }

        let gathered = LampSyncLocalFiles.devotionalMedia(
            for: [], remoteModuleID: "writing", inLibraryAt: root,
            members: ["WritingMedia/writing/W1/anything.jpg"]
        )

        #expect(gathered.candidates.isEmpty)
    }
}
