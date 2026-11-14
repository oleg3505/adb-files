// swift-tools-version: 6.0
// Tools version 6.0 enables the Swift 6 language mode (strict concurrency checking) for all targets.

import PackageDescription

let package = Package(
    name: "AdbFiles",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AdbFiles", targets: ["AdbFiles"]),
        .library(name: "AdbKit", targets: ["AdbKit"]),
    ],
    targets: [
        // ADB protocol client. Must not import SwiftUI or AppKit.
        .target(name: "AdbKit"),
        // The macOS app.
        .executableTarget(
            name: "AdbFiles",
            dependencies: ["AdbKit"]
        ),
        .testTarget(
            name: "AdbKitTests",
            dependencies: ["AdbKit"]
        ),
        // App logic (stores, sorting, caching) via `@testable import AdbFiles`.
        .testTarget(
            name: "AdbFilesTests",
            dependencies: ["AdbFiles", "AdbKit"]
        ),
    ]
)
