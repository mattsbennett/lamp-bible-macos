import Foundation

/// Where a writing's agent workspace lives, and what is in it.
///
/// The app has always known this; the helper now needs it too, because a tool
/// names a writing by its identifier and has to find the folder itself. The
/// derivation lives here so there is exactly one of it: two copies of a
/// path-deriving hash would not fail, they would quietly point at a different
/// folder, and the symptom would be a writing that appears to have no
/// workspace while its workspace sits beside it under another name.
///
/// A tool names a writing by identifier and never by path, which is what keeps
/// an outside app from reaching a file of its own choosing.
public enum LampWritingWorkspace {
    public static let draftFilename = "draft.md"
    public static let contextFilename = "DEVOTIONAL_CONTEXT.md"
    public static let identifierFilename = "DEVOTIONAL_ID"

    /// `<library>/AgentWorkspaces/Devotionals/<folder>`.
    public static func url(libraryRootURL: URL, writingID: String) -> URL {
        libraryRootURL
            .appendingPathComponent("AgentWorkspaces", isDirectory: true)
            .appendingPathComponent("Devotionals", isDirectory: true)
            .appendingPathComponent(directoryName(for: writingID), isDirectory: true)
    }

    /// A folder name from an identifier: as much of it as reads as a name,
    /// then a hash of the whole so two writings never collide.
    ///
    /// Every existing workspace on every device is named by this function, so
    /// its output is a stored format in all but name. Changing it orphans
    /// them, which is why `aknownIdentifierKeepsItsFolderName` pins one.
    public static func directoryName(for identifier: String) -> String {
        let readable = identifier.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar)) : "_"
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let prefix = String(readable.prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(prefix.isEmpty ? "devotional" : prefix)-\(String(hash, radix: 16))"
    }

    /// Whether this writing has a workspace at all.
    ///
    /// A writing that has never been opened in its agent pane has none, and
    /// one is not made here: scaffolding a workspace means writing the context
    /// document and the agent instructions as Lamp writes them, which is Lamp's
    /// to do and cannot be done well while Lamp is closed.
    public static func exists(
        libraryRootURL: URL,
        writingID: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let draft = url(libraryRootURL: libraryRootURL, writingID: writingID)
            .appendingPathComponent(draftFilename)
        return fileManager.fileExists(atPath: draft.path)
    }

    /// A writing that has a workspace, as a tool reports it.
    public struct Listed: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        /// The draft's first heading, or its first line of prose. Lamp keeps
        /// the authoritative title in the library; this is what the draft
        /// itself says, which is what an agent about to edit it should match.
        public let title: String?
        public let draftCharacters: Int
        public let hasContext: Bool
        public let changedAt: Date?
    }

    /// Every writing with a workspace, newest change first.
    ///
    /// Read from the folders rather than from the library, because having a
    /// workspace is exactly what makes a writing reachable by these tools, and
    /// the folder is what decides that. Each one records its own writing's
    /// identifier, so no name has to be derived backwards out of a folder.
    public static func listed(
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) -> [Listed] {
        let root = libraryRootURL
            .appendingPathComponent("AgentWorkspaces", isDirectory: true)
            .appendingPathComponent("Devotionals", isDirectory: true)
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var writings: [Listed] = []
        for folder in folders {
            let draft = folder.appendingPathComponent(draftFilename)
            guard fileManager.fileExists(atPath: draft.path),
                  let identifier = try? String(
                      contentsOf: folder.appendingPathComponent(identifierFilename),
                      encoding: .utf8
                  ).trimmingCharacters(in: .whitespacesAndNewlines),
                  !identifier.isEmpty
            else { continue }
            let text = (try? String(contentsOf: draft, encoding: .utf8)) ?? ""
            writings.append(Listed(
                id: identifier,
                title: title(ofDraft: text),
                draftCharacters: text.count,
                hasContext: fileManager.fileExists(
                    atPath: folder.appendingPathComponent(contextFilename).path
                ),
                changedAt: (try? draft.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            ))
        }
        return writings.sorted {
            ($0.changedAt ?? .distantPast) > ($1.changedAt ?? .distantPast)
        }
    }

    /// The draft's own title: its first Markdown heading, else its first line
    /// with words in it.
    public static func title(ofDraft draft: String) -> String? {
        for line in draft.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
            return trimmed
        }
        return nil
    }

    public static func readDraft(
        libraryRootURL: URL,
        writingID: String
    ) throws -> String {
        try String(
            contentsOf: url(libraryRootURL: libraryRootURL, writingID: writingID)
                .appendingPathComponent(draftFilename),
            encoding: .utf8
        )
    }

    /// The context document Lamp wrote for the agent, when there is one. Absent
    /// rather than an error: a workspace without one is usable.
    public static func readContext(
        libraryRootURL: URL,
        writingID: String
    ) -> String? {
        try? String(
            contentsOf: url(libraryRootURL: libraryRootURL, writingID: writingID)
                .appendingPathComponent(contextFilename),
            encoding: .utf8
        )
    }
}
