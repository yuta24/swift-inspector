// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectServer",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "InspectServer", targets: ["InspectServer"]),
    ],
    dependencies: [
        .package(path: "../InspectCore"),
        .package(url: "https://github.com/devicekit/DeviceKit.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "InspectServer",
            dependencies: [
                .product(name: "InspectCore", package: "InspectCore"),
                .product(name: "DeviceKit", package: "DeviceKit"),
            ]
        ),
        .testTarget(
            name: "InspectServerTests",
            dependencies: ["InspectServer"],
            // The implementation files are gated by
            // `(DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)`.
            // Tests need the same gate so the symbols they exercise exist.
            swiftSettings: [
                .define("SWIFT_INSPECTOR_ENABLED")
            ]
        ),
    ]
)
