import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// The revisions of the files the manifest names but no folder listing
/// reaches. They used to be asked after one at a time — one request per
/// revision file, context file, transcript and picture, every pass — which at
/// two hundred and fifty workspaces is some fourteen thousand of them. Their
/// folders are listed instead.
///
/// What these hold is that the revisions handed back are the same ones, and
/// that the requests are counted: a listing a folder, and a file asked after
/// only where the listing could not answer.
struct UnlistedMemberRevisionsTests {
    /// A server that says what it was asked.
    private final class CountingStore: LampSyncRemoteStore, @unchecked Sendable {
        /// Listings by directory; a directory absent here cannot be listed.
        let listings: [String: [LampSyncRemoteEntry]]
        /// Revisions a file answers with when asked after directly.
        let perFile: [String: String]
        private(set) var listed: [String] = []
        private(set) var asked: [String] = []

        init(listings: [String: [LampSyncRemoteEntry]], perFile: [String: String] = [:]) {
            self.listings = listings
            self.perFile = perFile
        }

        func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
            listed.append(directory)
            return listings[directory]
        }

        func read(path: String) async throws -> LampSyncRemoteFile? { nil }

        func revision(path: String) async throws -> String? {
            asked.append(path)
            return perFile[path]
        }

        func write(
            _ data: Data, to path: String, condition: LampSyncWriteCondition
        ) async throws -> String? { nil }
    }

    private func file(_ path: String, revision: String?) -> LampSyncRemoteEntry {
        LampSyncRemoteEntry(
            path: path,
            name: String(path.split(separator: "/").last ?? ""),
            isDirectory: false,
            revision: revision,
            modifiedAt: nil,
            size: nil
        )
    }

    /// A WebDAV listing carries an ETag per file, so one request a folder
    /// answers for every file in it.
    @Test func aFoldersListingAnswersForEveryFileInIt() async throws {
        let store = CountingStore(listings: [
            "Workspaces/Writing/w1/Revisions": [
                file("Workspaces/Writing/w1/Revisions/a.json", revision: "etag-a"),
                file("Workspaces/Writing/w1/Revisions/b.json", revision: "etag-b"),
                file("Workspaces/Writing/w1/Revisions/c.json", revision: "etag-c"),
            ],
        ])

        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            [
                "Workspaces/Writing/w1/Revisions/a.json",
                "Workspaces/Writing/w1/Revisions/b.json",
                "Workspaces/Writing/w1/Revisions/c.json",
            ],
            from: store
        )

        #expect(revisions == [
            "Workspaces/Writing/w1/Revisions/a.json": "etag-a",
            "Workspaces/Writing/w1/Revisions/b.json": "etag-b",
            "Workspaces/Writing/w1/Revisions/c.json": "etag-c",
        ])
        #expect(store.listed == ["Workspaces/Writing/w1/Revisions"])
        #expect(store.asked.isEmpty, "three files, one request")
    }

    /// The folder provider's listing carries no revision, so those files are
    /// asked after as before — but only the ones the listing shows.
    @Test func aListingWithoutRevisionsAsksOnlyForWhatIsThere() async throws {
        let store = CountingStore(
            listings: [
                "WritingMedia/writing/w1": [
                    file("WritingMedia/writing/w1/here.png", revision: nil),
                ],
            ],
            perFile: ["WritingMedia/writing/w1/here.png": "sha256:aaa"]
        )

        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            ["WritingMedia/writing/w1/here.png", "WritingMedia/writing/w1/gone.png"],
            from: store
        )

        #expect(revisions == ["WritingMedia/writing/w1/here.png": "sha256:aaa"])
        #expect(store.asked == ["WritingMedia/writing/w1/here.png"])
        #expect(
            !store.asked.contains("WritingMedia/writing/w1/gone.png"),
            "a member the listing does not show costs no request"
        )
    }

    /// A server that will not list a folder behaves as it did: each file
    /// asked after.
    @Test func aFolderThatWillNotListFallsBackToAskingEachFile() async throws {
        let store = CountingStore(
            listings: [:],
            perFile: [
                "BookMedia/book/one.jpg": "etag-1",
                "BookMedia/book/two.jpg": "etag-2",
            ]
        )

        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            ["BookMedia/book/one.jpg", "BookMedia/book/two.jpg"], from: store
        )

        #expect(revisions == [
            "BookMedia/book/one.jpg": "etag-1",
            "BookMedia/book/two.jpg": "etag-2",
        ])
        #expect(store.asked.sorted() == ["BookMedia/book/one.jpg", "BookMedia/book/two.jpg"])
    }

    /// Many folders, many files: one request each folder, and the count is
    /// the point.
    @Test func theRequestsAreOnePerFolder() async throws {
        var listings: [String: [LampSyncRemoteEntry]] = [:]
        var paths: [String] = []
        for workspace in 0..<20 {
            let directory = "Workspaces/Writing/w\(workspace)/Revisions"
            var entries: [LampSyncRemoteEntry] = []
            for revision in 0..<50 {
                let path = "\(directory)/r\(revision).json"
                entries.append(file(path, revision: "etag-\(workspace)-\(revision)"))
                paths.append(path)
            }
            listings[directory] = entries
        }

        let store = CountingStore(listings: listings)
        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(paths, from: store)

        #expect(paths.count == 1_000)
        #expect(revisions.count == 1_000)
        // The whole point: a thousand files, twenty requests.
        #expect(store.listed.count == 20)
        #expect(store.asked.isEmpty)
    }
    /// A real WebDAV listing's paths are the hrefs the server returned, which
    /// carry the share prefix — and the members are store-relative.
    ///
    /// This is the one that was missed. Every fixture above builds entries
    /// whose `path` is already store-relative, so keying the listing on it
    /// looked right; against Synology, where an href is
    /// `/home/LampBible/Workspaces/…`, it matched **nothing**, for every
    /// member of every folder. Measured on the owner's library: all 169
    /// revision members came back `listed=false` while 124 of them were
    /// plainly on disk and had been uploaded from that very Mac, so `change`
    /// answered `.none` and every unlisted kind — revisions, context files,
    /// workspace files, writing documents — went silently unsynced from the
    /// moment the folder listing replaced asking after each file.
    @Test func matchesAlistingWhosePathsCarryTheSharePrefix() async throws {
        let prefix = "/home/LampBible/"
        let store = CountingStore(listings: [
            "Workspaces/Writing/w1/Revisions": [
                file(prefix + "Workspaces/Writing/w1/Revisions/a.json", revision: "etag-a"),
                file(prefix + "Workspaces/Writing/w1/Revisions/b.json", revision: "etag-b"),
            ],
        ])

        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            [
                "Workspaces/Writing/w1/Revisions/a.json",
                "Workspaces/Writing/w1/Revisions/b.json",
            ],
            from: store
        )

        #expect(revisions == [
            "Workspaces/Writing/w1/Revisions/a.json": "etag-a",
            "Workspaces/Writing/w1/Revisions/b.json": "etag-b",
        ])
        #expect(store.asked.isEmpty, "the listing answered, so no file was asked after")
    }

    /// And a listing that genuinely does not hold a member still falls
    /// through to asking after it, rather than a name from another folder
    /// answering for it.
    @Test func doesNotLetAnameFromElsewhereAnswer() async throws {
        let store = CountingStore(
            listings: [
                "Workspaces/Writing/w1/Revisions": [
                    file("/home/LampBible/Workspaces/Writing/w1/Revisions/a.json",
                         revision: "etag-a"),
                ],
            ],
            perFile: ["Workspaces/Writing/w1/Revisions/missing.json": "etag-asked"]
        )

        let revisions = await LampSyncLocalFiles.revisionsOfUnlistedMembers(
            ["Workspaces/Writing/w1/Revisions/missing.json"], from: store
        )

        #expect(revisions == [:], "absent from the listing is absent")
        #expect(store.asked.isEmpty, "and costs no request, which is the point of listing")
    }

}
