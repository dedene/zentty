// ===----------------------------------------------------------------------===//
//
// This source file is part of the FuzzyMatch open source project
//
// Copyright (c) 2026 Ordo One, AB. and the FuzzyMatch project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
// ===----------------------------------------------------------------------===//

/// Test helper wrappers that accept `[UInt8]` / `[Int32]` arrays and internally
/// call `withUnsafeBufferPointer` to bridge to the production API.
///
/// These wrappers keep test call sites clean and minimize the branch diff vs `main`
/// (where `.span` provides direct access). When migrating back to Span (Swift 6.2+),
/// delete this file and add `.span` to array arguments at each call site.

@testable import FuzzyMatch

// MARK: - Single-buffer wrappers

func computeBoundaryMask(bytes: [UInt8]) -> UInt64 {
    bytes.withUnsafeBufferPointer { computeBoundaryMask(bytes: $0) }
}

func computeBoundaryMaskCompressed(originalBytes: [UInt8], isASCII: Bool) -> UInt64 {
    originalBytes.withUnsafeBufferPointer { ptr in
        computeBoundaryMaskCompressed(originalBytes: ptr, isASCII: isASCII)
    }
}

func isWordBoundary(at position: Int, in bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { isWordBoundary(at: position, in: $0) }
}

func computeCharBitmaskWithASCIICheck(_ bytes: [UInt8]) -> (mask: UInt64, isASCII: Bool) {
    bytes.withUnsafeBufferPointer { computeCharBitmaskWithASCIICheck($0) }
}

func computeCharBitmaskCaseInsensitive(_ bytes: [UInt8]) -> UInt64 {
    bytes.withUnsafeBufferPointer { computeCharBitmaskCaseInsensitive($0) }
}

func countSharedTrigrams(candidateBytes: [UInt8], queryTrigrams: Set<UInt32>) -> Int {
    candidateBytes.withUnsafeBufferPointer { cPtr in
        countSharedTrigrams(candidateBytes: cPtr, queryTrigrams: queryTrigrams)
    }
}

func passesTrigramFilter(candidateBytes: [UInt8], queryTrigrams: Set<UInt32>, maxEditDistance: Int) -> Bool {
    candidateBytes.withUnsafeBufferPointer { cPtr in
        passesTrigramFilter(candidateBytes: cPtr, queryTrigrams: queryTrigrams, maxEditDistance: maxEditDistance)
    }
}

func calculateBonuses(
    matchPositions: [Int],
    positionCount: Int,
    candidateBytes: [UInt8],
    boundaryMask: UInt64,
    config: EditDistanceConfig
) -> Double {
    candidateBytes.withUnsafeBufferPointer { cPtr in
        calculateBonuses(
            matchPositions: matchPositions,
            positionCount: positionCount,
            candidateBytes: cPtr,
            boundaryMask: boundaryMask,
            config: config
        )
    }
}

// MARK: - Dual-buffer wrappers

func prefixEditDistance(
    query: [UInt8],
    candidate: [UInt8],
    state: inout EditDistanceState,
    maxEditDistance: Int
) -> Int? {
    query.withUnsafeBufferPointer { qPtr in
        candidate.withUnsafeBufferPointer { cPtr in
            prefixEditDistance(query: qPtr, candidate: cPtr, state: &state, maxEditDistance: maxEditDistance)
        }
    }
}

func substringEditDistance(
    query: [UInt8],
    candidate: [UInt8],
    state: inout EditDistanceState,
    maxEditDistance: Int
) -> Int? {
    query.withUnsafeBufferPointer { qPtr in
        candidate.withUnsafeBufferPointer { cPtr in
            substringEditDistance(query: qPtr, candidate: cPtr, state: &state, maxEditDistance: maxEditDistance)
        }
    }
}

func findMatchPositions(
    query: [UInt8],
    candidate: [UInt8],
    boundaryMask: UInt64,
    positions: inout [Int]
) -> Int {
    query.withUnsafeBufferPointer { qPtr in
        candidate.withUnsafeBufferPointer { cPtr in
            findMatchPositions(query: qPtr, candidate: cPtr, boundaryMask: boundaryMask, positions: &positions)
        }
    }
}

func optimalAlignment(
    query: [UInt8],
    candidate: [UInt8],
    boundaryMask: UInt64,
    positions: inout [Int],
    state: inout AlignmentState,
    config: EditDistanceConfig
) -> (positionCount: Int, bonus: Double) {
    query.withUnsafeBufferPointer { qPtr in
        candidate.withUnsafeBufferPointer { cPtr in
            optimalAlignment(
                query: qPtr,
                candidate: cPtr,
                boundaryMask: boundaryMask,
                positions: &positions,
                state: &state,
                config: config
            )
        }
    }
}

// MARK: - Triple-buffer wrapper

func smithWatermanScore(
    query: [UInt8],
    candidate: [UInt8],
    bonus: [Int32],
    state: inout SmithWatermanState,
    config: SmithWatermanConfig
) -> Int32 {
    query.withUnsafeBufferPointer { qPtr in
        candidate.withUnsafeBufferPointer { cPtr in
            bonus.withUnsafeBufferPointer { bPtr in
                smithWatermanScore(query: qPtr, candidate: cPtr, bonus: bPtr, state: &state, config: config)
            }
        }
    }
}
