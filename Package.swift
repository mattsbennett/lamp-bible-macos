// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lamp-bible-macos",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../lamp-bible-core"),
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
            ]
        ),
        .testTarget(
            name: "LampBibleMacTests",
            dependencies: ["LampBibleMacSupport"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
