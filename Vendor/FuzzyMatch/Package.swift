// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FuzzyMatch",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "FuzzyMatch",
            targets: ["FuzzyMatch"]
        )
    ],
    targets: [
        .target(
            name: "FuzzyMatch",
            path: "Sources/FuzzyMatch"
        ),
        .testTarget(
            name: "FuzzyMatchTests",
            dependencies: ["FuzzyMatch"],
            path: "Tests/FuzzyMatchTests"
        )
    ]
)
