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
    ],
    targets: [
        .target(
            name: "InspectServer",
            dependencies: [
                .product(name: "InspectCore", package: "InspectCore"),
            ]
        ),
    ]
)
