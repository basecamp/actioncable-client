// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ActionCable",
    platforms: [
        .iOS(.v16),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ActionCable", targets: ["ActionCable"]),
        .library(name: "ActionCableTesting", targets: ["ActionCableTesting"]),
    ],
    targets: [
        .target(
            name: "ActionCable",
            path: "Sources/ActionCable",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The in-memory transport a test plays the server on. It ships as its own
        // product so an application's tests can drive a client without a socket,
        // and so nothing in it is linked into the application itself.
        .target(
            name: "ActionCableTesting",
            dependencies: ["ActionCable"],
            path: "Sources/ActionCableTesting",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ActionCableTests",
            dependencies: ["ActionCable", "ActionCableTesting"],
            path: "Tests/ActionCableTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
