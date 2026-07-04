// swift-tools-version: 6.0

// Vendored from https://github.com/ordo-one/FuzzyMatch at 1.3.3 (Apache-2.0, see LICENSE).
// The only local change is the platform floor: upstream declares macOS 14 but the code
// is pure Foundation, and Zentty supports macOS 13.

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
        )
    ]
)
