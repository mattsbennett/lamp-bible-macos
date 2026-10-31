import Foundation

/// Setting Lamp up as an MCP server inside another app — Claude Desktop,
/// opencode, Codex, Cursor.
///
/// Every config here names one stable path: a small launcher script in
/// Application Support that finds the app and runs the helper inside it. A
/// config naming the helper directly breaks the first time the app moves or
/// updates, and the app whose config it is cannot be expected to notice; worse,
/// Lamp fixing it would mean editing another app's configuration file, which
/// Lamp does not do. One indirection, written once, avoids both.
///
/// Nothing here edits another app's files. These are strings for someone to
/// paste, and a bundle for Claude Desktop's own install dialog to accept or
/// refuse.
public struct LampExternalAppSetup: Equatable, Sendable {
    public static let bundleIdentifier = "com.neus.Lamp-Bible.macOS"
    public static let launcherFilename = "lamp-mcp-launch"
    /// What the server is called inside another app's config. Distinct from
    /// the workspace configs' "lamp", because these sit in an app's global
    /// configuration where a name is all the user has to go on.
    public static let serverName = "lamp-bible"

    /// The launcher this config names.
    public let launcherURL: URL
    public let appVersion: String

    public init(launcherURL: URL, appVersion: String = "0.1.0") {
        self.launcherURL = launcherURL
        self.appVersion = appVersion
    }

    public static func launcherURL(inApplicationSupport root: URL) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
            .appendingPathComponent(launcherFilename)
    }

    // MARK: - The launcher

    /// Finds Lamp and runs its helper, so that no config holds a path inside
    /// the app bundle.
    ///
    /// The usual install locations are tried before Spotlight, because they
    /// cost a stat each and `mdfind` depends on an index that may be disabled
    /// or still building. `--external` is passed here rather than left to each
    /// config: a helper reached through this script is being used from outside
    /// Lamp whichever app did the reaching, and the switch should be checked.
    public static func launcherScript(bundleIdentifier: String = bundleIdentifier) -> String {
        """
        #!/bin/sh
        # Written by Lamp Bible. Finds the app and runs its MCP helper, so that
        # an app's configuration need not hold a path inside the app bundle.
        set -eu

        BUNDLE_ID='\(bundleIdentifier)'
        HELPER='Contents/Helpers/lamp-mcp'

        for app in \\
            "$HOME/Applications/Lamp Bible.app" \\
            "/Applications/Lamp Bible.app" \\
            "$HOME/Applications/Lamp Bible Beta.app"
        do
            if [ -x "$app/$HELPER" ]; then
                exec "$app/$HELPER" --external "$@"
            fi
        done

        if command -v mdfind > /dev/null 2>&1; then
            app=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2> /dev/null | head -n 1 || true)
            if [ -n "${app:-}" ] && [ -x "$app/$HELPER" ]; then
                exec "$app/$HELPER" --external "$@"
            fi
        fi

        echo "lamp-mcp-launch: could not find Lamp Bible. Open the app once, then try again." >&2
        exit 127
        """ + "\n"
    }

    // MARK: - Claude Desktop

    /// The `.mcpb` manifest. Format 0.3, whose required fields are
    /// `manifest_version`, `name`, `version`, `description`, `author` and
    /// `server`; `mcp_config` is what the host actually spawns.
    ///
    /// The launcher is carried inside the bundle and named relatively, as the
    /// specification's own binary example does, so Claude Desktop runs a copy
    /// it unpacked rather than a path on this machine.
    public var mcpbManifestJSON: String {
        Self.prettyJSON([
            "manifest_version": "0.3",
            "name": "lamp-bible",
            "display_name": "Lamp Bible",
            "version": appVersion,
            // Not "read-only": since write_writing_draft an outside app can
            // replace a writing's draft, and since add_reading_plan it can ask
            // for a reading plan, once the writer turns those on. This is what
            // Claude Desktop shows when the bundle is installed, so it is the
            // one place a reader is told what they are agreeing to.
            "description": "Your Lamp Bible library in Claude: scripture, commentary, dictionaries, reading plans, books, writings and quizzes. Read-only unless you let it change your writings or add reading plans, in Lamp's Settings under AI & Agents.",
            "author": ["name": "Lamp Bible"],
            "server": [
                "type": "binary",
                "entry_point": "server/\(Self.launcherFilename)",
                "mcp_config": [
                    "command": "server/\(Self.launcherFilename)",
                    "args": [] as [String],
                ] as [String: Any],
            ] as [String: Any],
        ])
    }

    /// For `claude_desktop_config.json`, for someone who would rather paste
    /// than install a bundle.
    public var claudeDesktopJSON: String {
        Self.prettyJSON([
            "mcpServers": [
                Self.serverName: [
                    "command": launcherURL.path,
                    "args": [] as [String],
                ] as [String: Any],
            ],
        ])
    }

    // MARK: - The others

    public var openCodeJSON: String {
        Self.prettyJSON([
            "$schema": "https://opencode.ai/config.json",
            "mcp": [
                Self.serverName: [
                    "type": "local",
                    "command": [launcherURL.path],
                    "enabled": true,
                ] as [String: Any],
            ],
        ])
    }

    public var codexTOML: String {
        """
        # Add to ~/.codex/config.toml
        [mcp_servers.\(Self.serverName)]
        command = \(Self.quoted(launcherURL.path))
        args = []
        startup_timeout_sec = 15
        tool_timeout_sec = 60
        """ + "\n"
    }

    /// Cursor's `mcp.json`, which takes the same shape as Claude Desktop's
    /// under a different key.
    public var cursorJSON: String {
        Self.prettyJSON([
            "mcpServers": [
                Self.serverName: [
                    "command": launcherURL.path,
                    "args": [] as [String],
                ] as [String: Any],
            ],
        ])
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Which app a snippet is for, and what to tell someone about where it goes.
public struct LampExternalApp: Identifiable, Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case json, toml
    }

    public let id: String
    public let name: String
    /// Where this goes, in words, since Lamp does not put it there.
    public let destination: String
    public let format: Format
    public let snippet: String

    public init(id: String, name: String, destination: String, format: Format, snippet: String) {
        self.id = id
        self.name = name
        self.destination = destination
        self.format = format
        self.snippet = snippet
    }
}

extension LampExternalAppSetup {
    /// The apps Lamp offers a snippet for, in the order they are shown.
    /// Claude Desktop is not here: it gets the bundle, which installs itself
    /// through Claude's own dialog.
    public var pasteableApps: [LampExternalApp] {
        [
            LampExternalApp(
                id: "opencode",
                name: "opencode",
                destination: "~/.config/opencode/opencode.json",
                format: .json,
                snippet: openCodeJSON
            ),
            LampExternalApp(
                id: "codex",
                name: "Codex",
                destination: "~/.codex/config.toml",
                format: .toml,
                snippet: codexTOML
            ),
            LampExternalApp(
                id: "cursor",
                name: "Cursor",
                destination: "~/.cursor/mcp.json",
                format: .json,
                snippet: cursorJSON
            ),
            LampExternalApp(
                id: "claude-desktop",
                name: "Claude Desktop, by hand",
                destination:
                    "~/Library/Application Support/Claude/claude_desktop_config.json",
                format: .json,
                snippet: claudeDesktopJSON
            ),
        ]
    }
}

/// Puts the launcher and the bundle on disk. Assembling a directory is here,
/// where it can be tested; compressing it into a `.mcpb` is the app's, since
/// that needs a process.
public enum LampExternalAppInstaller {
    @discardableResult
    public static func installLauncher(
        inApplicationSupport root: URL,
        bundleIdentifier: String = LampExternalAppSetup.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(LampExternalAppSetup.launcherFilename)
        try Data(
            LampExternalAppSetup.launcherScript(bundleIdentifier: bundleIdentifier).utf8
        ).write(to: destination, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path
        )
        return destination
    }

    /// Lays out what a `.mcpb` holds: the manifest at the root, and the
    /// launcher under `server/`, where the manifest says it is.
    @discardableResult
    public static func writeBundleContents(
        _ setup: LampExternalAppSetup,
        to directory: URL,
        bundleIdentifier: String = LampExternalAppSetup.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        let server = directory.appendingPathComponent("server", isDirectory: true)
        try fileManager.createDirectory(at: server, withIntermediateDirectories: true)
        try Data(setup.mcpbManifestJSON.utf8).write(
            to: directory.appendingPathComponent("manifest.json"), options: .atomic
        )
        let launcher = server
            .appendingPathComponent(LampExternalAppSetup.launcherFilename)
        try Data(
            LampExternalAppSetup.launcherScript(bundleIdentifier: bundleIdentifier).utf8
        ).write(to: launcher, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: launcher.path
        )
        return directory
    }
}
