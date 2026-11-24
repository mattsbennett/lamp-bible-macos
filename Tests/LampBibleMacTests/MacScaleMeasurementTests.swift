import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Phase 0 of `lamp-bible-core/Documentation/ScalabilityPlan.md`, the Mac's
/// half: what a sync pass spends on this app's own files, and what the
/// six-second probe costs, at a size nobody has yet.
///
/// Skipped unless `LAMP_SCALE=1`:
///
///     LAMP_SCALE=1 swift test --filter MacScaleMeasurementTests
///
/// Debug, unlike core's, for two reasons. This target cannot build in Release
/// at all — `AgentChatModelTests` uses a hook declared under `#if DEBUG` — and
/// what is measured here is file copies, directory walks and stats, which a
/// Release build does not make faster.
///
/// Sizes are environment variables: `LAMP_SCALE_WORKSPACES=50,250,1000`,
/// `LAMP_SCALE_WORKSPACE_DOCUMENTS=5`, `LAMP_SCALE_WORKSPACE_REVISIONS=50`.
/// Every line of output begins `SCALE`. Nothing asserts a timing.
struct MacScaleMeasurementTests {
    private static func enabled() -> Bool {
        ProcessInfo.processInfo.environment["LAMP_SCALE"] == "1"
    }

    private func sizes(_ variable: String, _ fallback: [Int]) -> [Int] {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return fallback }
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? fallback : parsed.sorted()
    }

    private func count(_ variable: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[variable].flatMap(Int.init) ?? fallback
    }

    /// How many regular files sit under `root`.
    private static func files(under root: URL) -> Int {
        (try? FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter {
                var isDirectory: ObjCBool = false
                let path = root.appendingPathComponent($0).path
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                else { return false }
                return !isDirectory.boolValue
            }.count) ?? 0
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> (value: T, ms: Double) {
        let clock = ContinuousClock()
        var result: T?
        let elapsed = try clock.measure { result = try body() }
        return (result!, Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1_000)
    }

    /// A workspace as the app keeps one: documents beside a draft, a context
    /// folder, revision history, and a conversation.
    private func makeWorkspace(
        _ index: Int, in libraryRoot: URL, documents: Int, revisions: Int,
        mergeable: Bool = false
    ) throws {
        let workspace = LampWritingWorkspace.url(
            libraryRootURL: libraryRoot, writingID: "scale-writing-\(index)"
        )
        let context = workspace.appendingPathComponent("context", isDirectory: true)
        let history = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        for directory in [workspace, context, history] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let body = String(repeating: "A paragraph of the writing, as it stands. ", count: 120)
        try Data(body.utf8).write(to: workspace.appendingPathComponent("draft.md"))
        for document in 0..<documents {
            try Data(body.utf8).write(
                to: workspace.appendingPathComponent("document-\(document).md")
            )
        }
        try Data("Context gathered for this writing.".utf8).write(
            to: context.appendingPathComponent("passage.md")
        )
        try writeRevisions(revisions, into: history, body: body, mergeable: mergeable)
    }

    /// Each revision keeps the document on either side of the change, which
    /// is what makes a folder megabytes (`AgentRevisionSupport`).
    ///
    /// Encoded through `DevotionalAgentRevision` itself, and named as the
    /// store names them. Hand-written JSON here called the two sides
    /// `before` and `after` where the type calls them `beforeMarkdown` and
    /// `afterMarkdown`, so every revision failed to decode and anything that
    /// read the history measured a folder of files it was throwing away.
    /// Caught by a Codex review of the first version of this.
    ///
    /// `mergeable` decides whether compaction has work to do. A real
    /// library's history is mostly already merged, which is what the gather
    /// should be measured against; `false` spaces the revisions two days
    /// apart, past the policy's oldest gap of a day, so they stand.
    private func writeRevisions(
        _ count: Int, into history: URL, body: String, mergeable: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let step: TimeInterval = mergeable ? 10 * 60 : 2 * 86_400
        // Aged two days, so the policy's hour-gap tier applies: ten minutes
        // apart merges, two days apart does not.
        let start = Date().addingTimeInterval(-2 * 86_400 - Double(count) * step)
        for index in 0..<count {
            // Contiguous: a run merges only where each revision's before is
            // the one before it's after.
            let revision = DevotionalAgentRevision(
                createdAt: start.addingTimeInterval(Double(index) * step),
                kind: .userEdit,
                documentPath: "draft.md",
                beforeMarkdown: "\(body.prefix(400)) v\(index)",
                afterMarkdown: "\(body.prefix(400)) v\(index + 1)"
            )
            let stamp = Int64(revision.createdAt.timeIntervalSince1970 * 1_000)
            try encoder.encode(revision).write(
                to: history.appendingPathComponent("\(stamp)-\(revision.id.uuidString).json")
            )
        }
    }

    /// What migrating and compacting every workspace costs, which is what a
    /// pass would pay to run its preparation at the front instead of inside
    /// its import (`lamp-bible-core/Documentation/decisions/0009` rejects
    /// that, and this is the number).
    ///
    /// Its own library, with its own workspaces, because compaction deletes
    /// the very revision files the gather above measures over. The first
    /// call has a merge to do; the second is what a pass would pay once the
    /// history is already merged, which is nearly every pass.
    @Test(.enabled(if: enabled()))
    @WritingWorkspaceFiles
    func measuresWhatPreparingTheLibraryCosts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-prepare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = count("LAMP_SCALE_WORKSPACE_DOCUMENTS", 5)
        let revisions = count("LAMP_SCALE_WORKSPACE_REVISIONS", 50)

        // Two libraries: one with a backlog to merge, and one whose history
        // is already as compact as the policy allows and still holds every
        // revision. The second is the steady state — what a pass would pay
        // every time, for nothing.
        // A library of each kind per size. Reusing one across sizes let the
        // smaller run compact the larger run's backlog first, so
        // `prepareWithAMergeToDo` at 250 depended on whether 50 had run.
        for target in sizes("LAMP_SCALE_WORKSPACES", [50, 250, 1_000]) {
            let libraryRoot = root.appendingPathComponent("Backlog-\(target)")
            let settledRoot = root.appendingPathComponent("Settled-\(target)")
            for index in 0..<target {
                try makeWorkspace(
                    index, in: libraryRoot, documents: documents, revisions: revisions,
                    mergeable: true
                )
                try makeWorkspace(
                    index, in: settledRoot, documents: documents, revisions: revisions,
                    mergeable: false
                )
            }
            // The settled library is prepared once untimed first: a
            // workspace with no skill selection yet has one written for it,
            // and those one-time writes are not what a recurring pass pays.
            try LampWorkspaceSync.prepareLibraryForSync(at: settledRoot)

            let first = try timed { try LampWorkspaceSync.prepareLibraryForSync(at: libraryRoot) }
            let again = try timed { try LampWorkspaceSync.prepareLibraryForSync(at: libraryRoot) }
            let settled = try timed { try LampWorkspaceSync.prepareLibraryForSync(at: settledRoot) }
            // Only the history: preparation writes skill selections beside
            // it, and counting those as revisions overstated what compaction
            // had kept.
            func revisionFiles(in root: URL) -> Int {
                (try? FileManager.default.subpathsOfDirectory(atPath: root.path)
                    .filter { $0.hasSuffix(".json") && $0.contains(".lamp/revisions/") }.count) ?? 0
            }
            print("""
                SCALE workspaces=\(target) revisions=\(revisions) \
                prepareWithAMergeToDo=\(String(format: "%.0f", first.ms))ms \
                prepareAlreadyMerged=\(String(format: "%.0f", again.ms))ms \
                prepareSettledHistory=\(String(format: "%.0f", settled.ms))ms \
                filesLeftAfterMerging=\(revisionFiles(in: libraryRoot)) \
                filesInSettled=\(revisionFiles(in: settledRoot))
                """)
        }
    }

    @Test(.enabled(if: enabled()))
    @WritingWorkspaceFiles
    func measuresWhatAPassSpendsOnThisMacsOwnFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mac-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("Library")
        let documents = count("LAMP_SCALE_WORKSPACE_DOCUMENTS", 5)
        let revisions = count("LAMP_SCALE_WORKSPACE_REVISIONS", 50)

        var made = 0
        for target in sizes("LAMP_SCALE_WORKSPACES", [50, 250, 1_000]) {
            while made < target {
                try makeWorkspace(made, in: libraryRoot, documents: documents, revisions: revisions)
                made += 1
            }
            let scratch = root.appendingPathComponent("scratch-\(target)")

            let staged = try timed {
                try LampSyncLocalFiles.workspaceFiles(inLibraryAt: libraryRoot, stagingIn: scratch)
            }
            // Every candidate the gather hands on still has to be digested.
            // Timed on a *repeat* gather, so that this and the cached figure
            // below have had the same warm-up: the first describe of a
            // freshly written library reads colder files than any later one,
            // and crediting that difference to the cache is how the saving
            // was overstated twice over.
            _ = LampSyncLocalFiles.describe(staged.value, digests: nil)
            let uncachedAgain = try LampSyncLocalFiles.workspaceFiles(
                inLibraryAt: libraryRoot,
                stagingIn: root.appendingPathComponent("uncached-\(target)")
            )
            let hashed = timed {
                LampSyncLocalFiles.describe(uncachedAgain, digests: nil)
            }
            // And again with a cache, through the real code path: the
            // candidates the exporter marked as fixed at their path are
            // answered from it, and the staged ones are read as before. This
            // is what a second pass of a session actually pays.
            //
            // An earlier version relabelled every candidate `.module(.books)`
            // to force a hit, and reported the result as the cached case.
            // That overstated it: a staged file is written into a scratch
            // directory named per pass, so it has a new path every time and
            // can never be answered. The figure below is the reachable one.
            //
            // Gathered again into a fresh scratch directory for the timed
            // run, as a real second pass does: the staged files are new
            // files at new paths, so they are read cold there as they would
            // be in life. Reusing the first gather's scratch files credited
            // their warm pages to the cache.
            let cache = LampSyncDigestCache()
            _ = LampSyncLocalFiles.describe(staged.value, digests: cache)
            let again = try LampSyncLocalFiles.workspaceFiles(
                inLibraryAt: libraryRoot, stagingIn: root.appendingPathComponent("second-\(target)")
            )
            let fromCache = timed { LampSyncLocalFiles.describe(again, digests: cache) }
            let fixed = again.filter(\.isFixedAtItsPath).count
            let marks = timed { LampSyncLocalWork.marks(inLibraryAt: libraryRoot) }
            let bytes = Self.files(under: scratch)
            // And the same export the old way — copying everything into
            // scratch, which is what `0008` removed — so the files are
            // counted alike on both sides.
            //
            // This times the **copy alone**, where `exportAndEnumerate`
            // times the whole gather; the old gather also walked the copied
            // tree and built candidates from it, and that code is gone. The
            // full old gather is the 2 980 ms in `ScalabilityPlan.md`,
            // measured before the change. Do not read this against
            // `exportAndEnumerate` as though they were the same work.
            let copying = root.appendingPathComponent("copying-\(target)")
            let byCopying = try timed {
                try LampWorkspaceSync.exportPortableWorkspaces(
                    from: libraryRoot, to: copying, writingFolder: .perFile
                )
            }

            #expect(staged.value.count >= target)
            print("""
                SCALE workspaces=\(target) documents=\(documents) revisions=\(revisions) \
                exportAndEnumerate=\(String(format: "%.0f", staged.ms))ms \
                stagedFiles=\(bytes) candidates=\(staged.value.count) \
                exportByCopying=\(String(format: "%.0f", byCopying.ms))ms \
                filesByCopying=\(Self.files(under: copying)) \
                digest=\(String(format: "%.0f", hashed.ms))ms \
                digestWithACache=\(String(format: "%.0f", fromCache.ms))ms \
                fixedAtTheirPath=\(fixed) \
                digested=\(hashed.value.files.count) \
                localWorkProbe=\(String(format: "%.0f", marks.ms))ms \
                marks=\(marks.value.count)
                """)
        }
    }
}
