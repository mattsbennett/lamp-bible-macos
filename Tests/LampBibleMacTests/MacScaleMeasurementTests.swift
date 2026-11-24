import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Phase 0 of `lamp-bible-core/Documentation/ScalabilityPlan.md`, the Mac's
/// half: what a sync pass spends on this app's own files, and what the
/// six-second probe costs, at a size nobody has yet.
///
/// Skipped unless `LAMP_SCALE=1`. Run in Release — the point is the numbers:
///
///     LAMP_SCALE=1 swift test -c release --filter MacScaleMeasurementTests
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
        _ index: Int, in libraryRoot: URL, documents: Int, revisions: Int
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
        // Each revision keeps the document on either side of the change,
        // which is what makes a folder megabytes (`AgentRevisionSupport`).
        for revision in 0..<revisions {
            let json = """
                {"id":"\(UUID().uuidString)","createdAt":\(1_700_000_000 + revision),
                 "kind":"userEdit","documentPath":"draft.md",
                 "before":"\(body.prefix(400))","after":"\(body.prefix(420))"}
                """
            try Data(json.utf8).write(
                to: history.appendingPathComponent("\(1_700_000_000 + revision)-\(UUID().uuidString).json")
            )
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
            let marks = timed { LampSyncLocalWork.marks(inLibraryAt: libraryRoot) }
            let bytes = (try? FileManager.default.subpathsOfDirectory(atPath: scratch.path).count) ?? 0

            #expect(staged.value.count >= target)
            print("""
                SCALE workspaces=\(target) documents=\(documents) revisions=\(revisions) \
                exportAndEnumerate=\(String(format: "%.0f", staged.ms))ms \
                stagedFiles=\(bytes) candidates=\(staged.value.count) \
                localWorkProbe=\(String(format: "%.0f", marks.ms))ms \
                marks=\(marks.value.count)
                """)
        }
    }
}
