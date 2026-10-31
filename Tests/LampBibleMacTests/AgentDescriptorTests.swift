import Foundation
import Testing
@testable import LampBibleMacSupport

/// The descriptor is how `lamp-mcp`, started by another app with no arguments,
/// finds the library and the policy. Everything here is about it failing
/// safely: an outside app reads whatever this says, so "absent" and
/// "unreadable" must never come out as "allowed".
struct AgentDescriptorTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-descriptor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func descriptor(allowsExternalApps: Bool = true) -> LampAgentDescriptor {
        LampAgentDescriptor(
            libraryRootPath: "/Users/someone/Lamp/Library",
            policyPath: "/Users/someone/Lamp/AgentAccessPolicy.json",
            bundledModulesArchivePath: "/Applications/Lamp Bible.app/Contents/Resources/Modules.zip",
            allowsExternalApps: allowsExternalApps
        )
    }

    @Test func itgoesWhereBothTheAppAndAHelperLook() throws {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

        #expect(
            LampAgentDescriptorStore.url(inApplicationSupport: root).path
                == "/Users/someone/Library/Application Support/Lamp Bible/agent-descriptor.json"
        )
    }

    @Test func awrittenDescriptorReadsBackAsItself() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try LampAgentDescriptorStore.write(descriptor(), inApplicationSupport: root)
        #expect(FileManager.default.fileExists(atPath: written.path))

        let read = try LampAgentDescriptorStore.read(inApplicationSupport: root)
        #expect(read == descriptor())
        #expect(read.libraryRootURL.path == "/Users/someone/Lamp/Library")
        #expect(read.bundledModulesArchiveURL?.lastPathComponent == "Modules.zip")
    }

    /// The directory does not exist until something makes it, and the first
    /// write is usually that something.
    @Test func writingCreatesTheDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let unmade = root.appendingPathComponent("not-yet", isDirectory: true)

        let written = try LampAgentDescriptorStore.write(
            descriptor(), inApplicationSupport: unmade
        )

        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    // MARK: - Failing safely

    @Test func anabsentDescriptorSaysWhereToLookAndHowToMakeOne() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: LampAgentDescriptorStore.StoreError.self) {
            try LampAgentDescriptorStore.read(inApplicationSupport: root)
        }
        let message = LampAgentDescriptorStore.StoreError
            .missing(LampAgentDescriptorStore.url(inApplicationSupport: root))
            .localizedDescription
        #expect(message.contains("Settings"), "the reader is a person reading stderr")
    }

    @Test func rubbishIsRefusedRatherThanPartlyBelieved() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: LampAgentDescriptorStore.directoryURL(inApplicationSupport: root),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(
            to: LampAgentDescriptorStore.url(inApplicationSupport: root)
        )

        #expect(throws: LampAgentDescriptorStore.StoreError.self) {
            try LampAgentDescriptorStore.read(inApplicationSupport: root)
        }
    }

    /// A descriptor from a newer Lamp than the helper. Serving the wrong
    /// library or the wrong policy is worse than not starting.
    @Test func adescriptorFromALaterLampIsRefused() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var later = descriptor()
        later.version = LampAgentDescriptor.currentVersion + 1
        try LampAgentDescriptorStore.write(later, inApplicationSupport: root)

        #expect(throws: LampAgentDescriptorStore.StoreError.self) {
            try LampAgentDescriptorStore.read(inApplicationSupport: root)
        }
    }

    /// The field that was not there yet cannot read as permission.
    @Test func adescriptorWithoutTheSwitchIsOff() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: LampAgentDescriptorStore.directoryURL(inApplicationSupport: root),
            withIntermediateDirectories: true
        )
        try Data(#"{"libraryRootPath":"/l","policyPath":"/p"}"#.utf8).write(
            to: LampAgentDescriptorStore.url(inApplicationSupport: root)
        )

        let read = try LampAgentDescriptorStore.read(inApplicationSupport: root)
        #expect(read.allowsExternalApps == false)
        #expect(read.allowsExternalWriting == false)
        #expect(read.allowsExternalReadingPlans == false)
        #expect(throws: LampAgentDescriptorStore.StoreError.externalAppsNotAllowed) {
            try LampAgentDescriptorStore.readForExternalUse(inApplicationSupport: root)
        }
    }

    @Test func thedefaultIsOff() {
        let descriptor = LampAgentDescriptor(libraryRootPath: "/l", policyPath: "/p")

        #expect(descriptor.allowsExternalApps == false)
        // Each switch is its own: reading cannot grant writing, and neither
        // grants adding a reading plan.
        #expect(descriptor.allowsExternalWriting == false)
        #expect(descriptor.allowsExternalReadingPlans == false)
    }

    /// Switched off is a different answer from missing, and says a different
    /// thing: one is "turn it on", the other "there is nothing here".
    @Test func beingSwitchedOffIsSaidDifferentlyFromBeingAbsent() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampAgentDescriptorStore.write(
            descriptor(allowsExternalApps: false), inApplicationSupport: root
        )

        #expect(throws: LampAgentDescriptorStore.StoreError.externalAppsNotAllowed) {
            try LampAgentDescriptorStore.readForExternalUse(inApplicationSupport: root)
        }
        // Readable in itself: it is the permission that is missing, not the file.
        #expect(try LampAgentDescriptorStore.read(inApplicationSupport: root).allowsExternalApps == false)

        let message = LampAgentDescriptorStore.StoreError.externalAppsNotAllowed.localizedDescription
        #expect(message.contains("Settings"))
    }

    @Test func beingSwitchedOnIsWhatLetsAHelperServe() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampAgentDescriptorStore.write(descriptor(), inApplicationSupport: root)

        let read = try LampAgentDescriptorStore.readForExternalUse(inApplicationSupport: root)
        #expect(read.allowsExternalApps)
    }
}
