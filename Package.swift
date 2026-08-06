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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .target(
            name: "LampBibleMacSupport",
            dependencies: [
                .product(name: "LampModuleKit", package: "lamp-bible-core"),
            ]
        ),
        .executableTarget(
            name: "LampBibleMac",
            dependencies: [
                "LampBibleMacSupport",
                .product(name: "LampCore", package: "lamp-bible-core"),
                .product(name: "LampModuleKit", package: "lamp-bible-core"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [
                .copy("Resources/TipTapEditor"),
            ]
        ),
        .target(
            name: "LampMCPServer",
            dependencies: [
                .product(name: "LampCore", package: "lamp-bible-core"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "LampMCP",
            dependencies: [
                "LampMCPServer",
                .product(name: "LampCore", package: "lamp-bible-core"),
            ]
        ),
        .testTarget(
            name: "LampBibleMacTests",
            dependencies: ["LampBibleMacSupport"]
        ),
        .testTarget(
            name: "LampMCPServerTests",
            dependencies: ["LampMCPServer"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
