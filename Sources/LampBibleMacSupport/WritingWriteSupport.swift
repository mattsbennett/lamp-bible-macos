import CryptoKit
import Foundation

/// Changing a writing's draft from outside Lamp.
///
/// The write goes to the workspace's `draft.md`, which Lamp already watches,
/// rather than into the library: that is the path Lamp imports from, so an
/// outside app and the workspace's own agent use the same one, and a write
/// made while Lamp is closed is taken up when it next opens the writing.
///
/// Nothing is reported as saved before it has happened. The draft is written
/// here and now; the *import* into the library is a later step, and the reply
/// says so rather than implying the library already holds it.
public enum LampWritingWrite {
    /// What a write was based on, and what it left, so the import can tell a
    /// writer's later edit from the text this replaced.
    ///
    /// Hashes and no text. The note exists to answer "has the library moved
    /// since this was written?", which a hash answers exactly, and keeping the
    /// prose out of it means the note is not a second copy of the writing.
    public struct Note: Codable, Equatable, Sendable {
        /// The draft this write was based on.
        public let baseFingerprint: String
        /// The draft this write left behind, so a note can be told from one
        /// describing a draft the writer has since changed in Lamp.
        public let draftFingerprint: String
        public let writtenAt: Date

        public init(baseFingerprint: String, draftFingerprint: String, writtenAt: Date = Date()) {
            self.baseFingerprint = baseFingerprint
            self.draftFingerprint = draftFingerprint
            self.writtenAt = writtenAt
        }
    }

    public enum WriteError: Error, LocalizedError, Equatable {
        case noWorkspace(String)
        case draftMovedOnDisk
        case writingChangedInLamp

        public var errorDescription: String? {
            switch self {
            case .noWorkspace(let id):
                return """
                The writing \(id) has no agent workspace, so there is nowhere \
                to put a draft. Open it in Lamp and show its agent pane once.
                """
            case .draftMovedOnDisk:
                return """
                The draft has changed since you read it, so this write was \
                refused rather than applied over it. Read the writing again, \
                reconcile your changes with what is there now, and write once \
                more.
                """
            case .writingChangedInLamp:
                return """
                The writer has changed this writing in Lamp since you read it, \
                so this write was refused rather than applied over their work. \
                Read the writing again and reconcile your changes with theirs.
                """
            }
        }
    }

    /// A text's identity, for comparing one copy against another.
    ///
    /// Composed first: the same words typed on two keyboards can differ by
    /// where the accents live, and two spellings of one sentence must not read
    /// as two different drafts.
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Writes the draft, if nothing has moved under it.
    ///
    /// `basedOn` is the draft the caller read. It has to match both the draft
    /// on disk and the writing as the library holds it: the first catches
    /// another agent's write, the second catches the writer's own editing in
    /// Lamp, which does not reach `draft.md` from every editor. Either way the
    /// write is refused rather than merged, because reconciling someone's
    /// prose is not a thing to do without them.
    @discardableResult
    public static func writeDraft(
        libraryRootURL: URL,
        applicationSupportURL: URL?,
        writingID: String,
        draft: String,
        basedOn: String,
        libraryText: String?,
        now: Date = Date()
    ) throws -> Note {
        guard LampWritingWorkspace.exists(
            libraryRootURL: libraryRootURL, writingID: writingID
        ) else {
            throw WriteError.noWorkspace(writingID)
        }
        let base = fingerprint(basedOn)
        let onDisk = try LampWritingWorkspace.readDraft(
            libraryRootURL: libraryRootURL, writingID: writingID
        )
        guard fingerprint(onDisk) == base else { throw WriteError.draftMovedOnDisk }
        if let libraryText, fingerprint(libraryText) != base {
            throw WriteError.writingChangedInLamp
        }

        let note = Note(
            baseFingerprint: base,
            draftFingerprint: fingerprint(draft),
            writtenAt: now
        )
        // The note first: a draft with no note is resolved by the old rule,
        // which takes the arriving copy. A note with no draft describes
        // nothing and is ignored. Of the two orders, only this one has no
        // state that silently discards the writer's text.
        if let applicationSupportURL {
            try writeNote(
                note,
                applicationSupportURL: applicationSupportURL,
                writingID: writingID
            )
        }
        try Data(draft.utf8).write(
            to: LampWritingWorkspace.url(libraryRootURL: libraryRootURL, writingID: writingID)
                .appendingPathComponent(LampWritingWorkspace.draftFilename),
            options: .atomic
        )
        return note
    }

    // MARK: - The note

    /// Beside the descriptor in Application Support, deliberately outside the
    /// library.
    ///
    /// The library syncs, and the workspace folders are gathered by name, so a
    /// note left in the workspace would travel to the user's server and down
    /// to their phone as a side effect of where it was put. Excluding it by
    /// name would work until someone changed the gather. Outside the library
    /// there is nothing to exclude and nothing to remember.
    public static func noteURL(applicationSupportURL: URL, writingID: String) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: applicationSupportURL)
            .appendingPathComponent("WritingWrites", isDirectory: true)
            .appendingPathComponent(
                "\(LampWritingWorkspace.directoryName(for: writingID)).json"
            )
    }

    static func writeNote(
        _ note: Note,
        applicationSupportURL: URL,
        writingID: String,
        fileManager: FileManager = .default
    ) throws {
        let destination = noteURL(
            applicationSupportURL: applicationSupportURL, writingID: writingID
        )
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: destination, options: .atomic)
    }

    public static func note(
        applicationSupportURL: URL,
        writingID: String
    ) -> Note? {
        let source = noteURL(
            applicationSupportURL: applicationSupportURL, writingID: writingID
        )
        guard let data = try? Data(contentsOf: source) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Note.self, from: data)
    }

    public static func forgetNote(
        applicationSupportURL: URL,
        writingID: String,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(
            at: noteURL(applicationSupportURL: applicationSupportURL, writingID: writingID)
        )
    }

    // MARK: - Importing

    /// What the import should do with a draft an outside app wrote.
    public enum Resolution: Equatable, Sendable {
        /// No note, so nothing is known about what this draft was based on.
        /// The old rule applies and the draft is taken.
        case takeDraftUnrecorded
        /// The library has not moved since the write, so the draft is the
        /// newer text and is taken.
        case takeDraft
        /// The writer has changed the writing since the write. Their text
        /// stays, and the outside version goes to history for them to see.
        case keepWritingAndRecordDraft
    }

    /// Decides between the writer's text and a draft written from outside.
    ///
    /// No times are compared. A clock says which write happened later, which
    /// is not the question; the question is whether the writing has moved
    /// since the draft was based on it, and the base fingerprint answers that
    /// exactly.
    ///
    /// A note whose `draftFingerprint` is not the draft now on disk describes
    /// a draft that has since been replaced — by the writer in the workspace,
    /// or by a later write — so it is ignored rather than applied to a draft
    /// it never saw.
    public static func resolve(
        note: Note?,
        draftOnDisk: String,
        libraryText: String
    ) -> Resolution {
        guard let note, note.draftFingerprint == fingerprint(draftOnDisk) else {
            return .takeDraftUnrecorded
        }
        return note.baseFingerprint == fingerprint(libraryText)
            ? .takeDraft
            : .keepWritingAndRecordDraft
    }
}
