// swift-tools-version: 5.9
import PackageDescription

// Single SwiftPM manifest for the library side of swift-inspector.
// The macOS client (InspectApp) keeps its own Package.swift because it
// needs Sparkle, which has no place leaking into the iOS library graph.
let package = Package(
    name: "swift-inspector",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "InspectServer", targets: ["InspectServer"]),
        .library(name: "InspectCore", targets: ["InspectCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "InspectCore",
            path: "InspectCore/Sources/InspectCore"
        ),
        .target(
            name: "InspectServer",
            dependencies: [
                "InspectCore",
                .product(name: "DeviceKit", package: "DeviceKit"),
            ],
            path: "InspectServer/Sources/InspectServer"
        ),
        .testTarget(
            name: "InspectCoreTests",
            dependencies: ["InspectCore"],
            path: "InspectCore/Tests/InspectCoreTests"
        ),
        .testTarget(
            name: "InspectServerTests",
            dependencies: ["InspectServer"],
            path: "InspectServer/Tests/InspectServerTests",
            // Mirror the host gate so the test binary can see the gated
            // implementation symbols.
            swiftSettings: [
                .define("SWIFT_INSPECTOR_ENABLED")
            ]
        ),
    ]
)
