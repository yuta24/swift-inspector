// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "InspectCore", targets: ["InspectCore"]),
    ],
    targets: [
        .target(name: "InspectCore"),
        .testTarget(name: "InspectCoreTests", dependencies: ["InspectCore"]),
    ]
)
