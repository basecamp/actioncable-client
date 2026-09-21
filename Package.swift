// swift-tools-version: 6.0
// The distribution manifest. SwiftPM resolves a package from the root of a
// repository and has no way to point at a subdirectory, so the Swift client's
// consumers get it from here. `swift/Package.swift` is the one to develop
// against: it carries the test target, and `make swift-check` builds it.
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
            path: "swift/Sources/ActionCable",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "ActionCableTesting",
            dependencies: ["ActionCable"],
            path: "swift/Sources/ActionCableTesting",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
