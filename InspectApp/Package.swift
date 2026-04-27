// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectApp",
    // The source-language strings in `Text("Connect")` etc. are English, so
    // English is the development region. `ja` is provided as a translation
    // via `Resources/Localizable.xcstrings`. Without `defaultLocalization`
    // SwiftPM will not process the catalog or expose other lprojs at runtime.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // Points at the unified library Package.swift at repo root.
        // Sparkle stays out of that package — it's macOS-client-only.
        .package(name: "swift-inspector", path: ".."),
        // Pinned to 2.9.x. Patch updates pick up Sparkle's security fixes;
        // a minor bump (e.g. 2.10) goes through manual verification because
        // the codesign / sign_update layout has shifted between releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.9.0"..<"2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppInspector",
            dependencies: [
                .product(name: "InspectCore", package: "swift-inspector"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "InspectApp",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "AppInspectorTests",
            dependencies: ["AppInspector"],
            path: "InspectAppTests"
        ),
    ]
)
