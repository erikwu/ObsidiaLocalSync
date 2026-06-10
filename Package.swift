// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SyncTwin",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "SyncTwin",
            targets: ["SyncTwin"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "SyncTwin",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices"),
                .linkedFramework("MultipeerConnectivity"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "SyncTwinTests",
            dependencies: ["SyncTwin"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
