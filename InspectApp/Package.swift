// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InspectApp",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(path: "../InspectCore"),
    ],
    targets: [
        .executableTarget(
            name: "InspectApp",
            dependencies: [
                .product(name: "InspectCore", package: "InspectCore"),
            ],
            path: "InspectApp",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
            ]
        ),
    ]
)
