// swift-tools-version: 6.0

// Vendored Zstandard (facebook/zstd, now meta/zstd) v1.5.7, decompressor only, as the
// single-file amalgamation `zstddeclib.c` (BSD-3-Clause, see LICENSE). Used to read
// compressed Codex rollouts (`*.jsonl.zst`). See README.md for how it was generated.

import PackageDescription

let package = Package(
    name: "Zstd",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CZstd",
            targets: ["CZstd"]
        )
    ],
    targets: [
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            sources: ["zstddeclib.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0")
            ]
        )
    ]
)
