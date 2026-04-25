// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectApp",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../InspectCore"),
        // Pinned to 2.9.x. Patch updates pick up Sparkle's security fixes;
        // a minor bump (e.g. 2.10) goes through manual verification because
        // the codesign / sign_update layout has shifted between releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.9.0"..<"2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "InspectApp",
            dependencies: [
                .product(name: "InspectCore", package: "InspectCore"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "InspectApp",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
            ]
        ),
    ]
)
