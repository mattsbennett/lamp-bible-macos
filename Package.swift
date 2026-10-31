// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lamp-bible-macos",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "lamp-mcp", targets: ["LampMCP"]),
    ],
    dependencies: [
        .package(path: "../lamp-bible-core"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // 1.12+ compiles optional Metal shaders in Xcode and therefore requires
        // Apple's separately installed Metal toolchain. 1.11.2 has the same PTY
        // API used here without imposing that unrelated build prerequisite.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        // Apache-2.0 SwiftUI chat components with first-class macOS support.
        .package(url: "https://github.com/EnesKaraosman/SwiftyChat.git", exact: "4.1.1"),
        // Direct-download auto-updates; the app isn't sandboxed, so it can't ship through the Mac App Store.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "LampBibleMacSupport",
            dependencies: [
                .product(name: "LampCore", package: "lamp-bible-core"),
                .product(name: "LampModuleKit", package: "lamp-bible-core"),
                .product(name: "LampPresentationUI", package: "lamp-bible-core"),
            ]
        ),
        .executableTarget(
            name: "LampBibleMac",
            dependencies: [
                "LampBibleMacSupport",
                .product(name: "LampCore", package: "lamp-bible-core"),
                .product(name: "LampModuleKit", package: "lamp-bible-core"),
                .product(name: "LampPresentationUI", package: "lamp-bible-core"),
                // Apple Intelligence, for making a reading plan from a
                // description. Weak-linked in core, so the app still launches
                // on a Mac with no FoundationModels to load.
                .product(name: "LampIntelligence", package: "lamp-bible-core"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SwiftyChat", package: "SwiftyChat"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/TipTapEditor"),
                .copy("Resources/AgentSkills"),
            ]
        ),
        .target(
            name: "LampMCPServer",
            dependencies: [
                // `writing_changes` reads the workspace's revision history, so
                // the server shares the store the app records it with rather
                // than re-deriving the folder layout. Xcode compiles those
                // sources into the helper target instead, hence the
                // `#if canImport` guard on the import.
                "LampBibleMacSupport",
                .product(name: "LampCore", package: "lamp-bible-core"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "LampMCP",
            dependencies: [
                "LampMCPServer",
                .product(name: "LampCore", package: "lamp-bible-core"),
                // `--render-deck` draws slides with the same canvas the apps
                // use, so a preview cannot disagree with the real thing.
                .product(name: "LampPresentationUI", package: "lamp-bible-core"),
            ]
        ),
        .testTarget(
            name: "LampBibleMacTests",
            dependencies: [
                "LampBibleMacSupport",
                .product(name: "LampCore", package: "lamp-bible-core"),
            ]
        ),
        .testTarget(
            name: "LampMCPServerTests",
            dependencies: ["LampMCPServer", "LampBibleMacSupport"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
