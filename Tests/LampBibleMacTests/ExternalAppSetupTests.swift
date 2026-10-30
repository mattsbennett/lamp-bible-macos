import Foundation
import Testing
@testable import LampBibleMacSupport

/// The configs Lamp hands to other apps, and the launcher they all name.
///
/// Lamp cannot test these by using them — each one is read by an app Lamp does
/// not control — so what is checked here is that they are the documented shape,
/// that they name the launcher rather than anything inside the app bundle, and
/// that the launcher itself is a shell script that would run.
struct ExternalAppSetupTests {
    private let launcher = URL(
        fileURLWithPath: "/Users/someone/Library/Application Support/Lamp Bible/lamp-mcp-launch"
    )

    private var setup: LampExternalAppSetup {
        LampExternalAppSetup(launcherURL: launcher, appVersion: "0.1.0")
    }

    private func json(_ string: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try #require(object as? [String: Any])
    }

    // MARK: - Every config names the launcher

    /// The point of the launcher: nothing a user pastes contains a path into
    /// the app bundle, which would break the next time the app is replaced.
    @Test func nosnippetNamesAnythingInsideTheAppBundle() {
        for app in setup.pasteableApps {
            #expect(
                !app.snippet.contains("Contents/Helpers"),
                "\(app.name) names the helper directly"
            )
            #expect(
                !app.snippet.contains(".app/"),
                "\(app.name) names a path inside an app bundle"
            )
            #expect(app.snippet.contains(launcher.path), "\(app.name) does not name the launcher")
        }
    }

    @Test func everySnippetSaysWhereItGoesAndParses() throws {
        #expect(setup.pasteableApps.count == 4)
        for app in setup.pasteableApps {
            #expect(app.destination.hasPrefix("~/"), "\(app.name) must say where it goes")
            if app.format == .json {
                _ = try json(app.snippet)
            } else {
                #expect(app.snippet.contains("[mcp_servers."), "\(app.name) is not a Codex table")
            }
        }
    }

    @Test func claudeDesktopAndCursorUseTheMcpServersShape() throws {
        for snippet in [setup.claudeDesktopJSON, setup.cursorJSON] {
            let servers = try #require(try json(snippet)["mcpServers"] as? [String: Any])
            let server = try #require(servers["lamp-bible"] as? [String: Any])
            #expect(server["command"] as? String == launcher.path)
            #expect((server["args"] as? [String])?.isEmpty == true)
        }
    }

    @Test func opencodeUsesItsOwnSchemaAndCommandArray() throws {
        let configuration = try json(setup.openCodeJSON)
        #expect(configuration["$schema"] as? String == "https://opencode.ai/config.json")
        let servers = try #require(configuration["mcp"] as? [String: Any])
        let server = try #require(servers["lamp-bible"] as? [String: Any])
        #expect(server["type"] as? String == "local")
        #expect(server["command"] as? [String] == [launcher.path])
        #expect(server["enabled"] as? Bool == true)
    }

    /// A path with a space in it — which the default one has, under
    /// "Application Support" — has to survive being written into TOML.
    @Test func codexTOMLQuotesThePath() {
        #expect(setup.codexTOML.contains("command = \"\(launcher.path)\""))
        #expect(setup.codexTOML.contains("args = []"))
    }

    // MARK: - The bundle

    /// Version 0.3's required fields, and a relative command, so Claude
    /// Desktop runs the copy it unpacked rather than one on this machine.
    @Test func themcpbManifestIsTheDocumentedShape() throws {
        let manifest = try json(setup.mcpbManifestJSON)

        for key in ["manifest_version", "name", "version", "description", "author", "server"] {
            #expect(manifest[key] != nil, "a manifest without \(key) is refused")
        }
        #expect(manifest["manifest_version"] as? String == "0.3")
        #expect(manifest["version"] as? String == "0.1.0")

        let server = try #require(manifest["server"] as? [String: Any])
        #expect(server["type"] as? String == "binary")
        #expect(server["entry_point"] as? String == "server/lamp-mcp-launch")

        let configuration = try #require(server["mcp_config"] as? [String: Any])
        let command = try #require(configuration["command"] as? String)
        #expect(command == "server/lamp-mcp-launch")
        #expect(
            !command.hasPrefix("/"),
            "an absolute path would point outside the bundle Claude unpacked"
        )
    }

    @Test func thebundleHoldsTheManifestAtItsRootAndTheLauncherWhereItSays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-mcpb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try LampExternalAppInstaller.writeBundleContents(setup, to: root)

        let manifest = root.appendingPathComponent("manifest.json")
        let entry = try #require(
            try json(String(contentsOf: manifest, encoding: .utf8))["server"] as? [String: Any]
        )["entry_point"] as? String
        let launcherInBundle = root.appendingPathComponent(try #require(entry))
        #expect(
            FileManager.default.isExecutableFile(atPath: launcherInBundle.path),
            "the manifest's entry_point must exist and be executable"
        )
    }

    // MARK: - The launcher itself

    @Test func thelauncherIsAnExecutableShellScript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = try LampExternalAppInstaller.installLauncher(inApplicationSupport: root)

        #expect(installed == LampExternalAppSetup.launcherURL(inApplicationSupport: root))
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        let script = try String(contentsOf: installed, encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"))
    }

    /// It passes `--external`, which is what makes the off-by-default switch
    /// apply to an app reaching Lamp this way.
    @Test func thelauncherAsksForExternalAccess() {
        let script = LampExternalAppSetup.launcherScript()

        #expect(script.contains("--external"))
        #expect(script.contains("Contents/Helpers/lamp-mcp"))
        #expect(script.contains(LampExternalAppSetup.bundleIdentifier))
        // Cheap checks before Spotlight, which may be indexing or off.
        let firstLocation = try? #require(script.range(of: "/Applications/Lamp Bible.app"))
        let spotlight = try? #require(script.range(of: "mdfind"))
        if let firstLocation, let spotlight {
            #expect(firstLocation.lowerBound < spotlight.lowerBound)
        }
    }

    /// A refusal has to reach the app's log as a non-zero exit, or the app
    /// shows a server that is silently doing nothing.
    @Test func thelauncherFailsLoudlyWhenLampIsNotThere() {
        let script = LampExternalAppSetup.launcherScript()

        #expect(script.contains("exit 127"))
        #expect(script.contains(">&2"), "the message must go to standard error")
    }
}

extension ExternalAppSetupTests {
    /// What Claude Desktop shows when someone installs the bundle, which is
    /// the one place a reader is told what they are agreeing to.
    ///
    /// It said "Read-only access", and has not been only that since
    /// `write_writing_draft`: with the setting on, an outside app can replace
    /// a writing's draft. lamp-bible-web-28 found it while making the site
    /// say the same thing.
    @Test func thebundleDoesNotPromiseReadOnly() throws {
        let manifest = try json(setup.mcpbManifestJSON)
        let description = try #require(manifest["description"] as? String)

        #expect(
            !description.lowercased().hasPrefix("read-only"),
            "the bundle must not open by calling itself read-only"
        )
        #expect(description.contains("writings"))
        #expect(
            description.contains("Settings"),
            "and must say where the writer turns writing on"
        )
    }
}
