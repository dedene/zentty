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

/// Trigram computation for fuzzy matching prefiltering.
///
/// Trigrams are consecutive 3-character sequences extracted from strings.
/// Similar strings tend to share many trigrams, so trigram comparison provides
/// a fast similarity estimate before computing expensive edit distance.
///
/// ## Example
///
/// ```
/// "hello" → {"hel", "ell", "llo"}
/// "hallo" → {"hal", "all", "llo"}
/// Shared: {"llo"} → 1 shared trigram
/// ```
///
/// ## Usage in FuzzyMatcher
///
/// Trigram filtering is applied for queries of 4+ characters. A candidate must
/// share at least `queryTrigrams.count - 3 * maxEditDistance` trigrams to pass.

/// Computes a trigram hash from three consecutive bytes.
///
/// Packs three bytes into a 32-bit integer for efficient storage and comparison.
///
/// - Parameters:
///   - a: First byte.
///   - b: Second byte.
///   - c: Third byte.
/// - Returns: A 32-bit hash combining the three bytes.
///
/// ## Implementation
///
/// ```
/// hash = byte0 | (byte1 << 8) | (byte2 << 16)
/// ```
///
/// This places each byte in a separate 8-bit region of the 32-bit integer,
/// creating a unique hash for each trigram.
@inlinable
internal func trigramHash(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt32 {
    UInt32(a) | (UInt32(b) << 8) | (UInt32(c) << 16)
}

/// Computes the set of trigrams for a sequence of bytes.
///
/// Extracts all consecutive 3-byte sequences and hashes them.
///
/// - Parameter bytes: The bytes to compute trigrams for (typically lowercased).
/// - Returns: A set of trigram hashes.
///
/// ## Example
///
/// ```swift
/// let trigrams = computeTrigrams(Array("hello".utf8))
/// // Returns hashes for: "hel", "ell", "llo"
/// // Count: 3 trigrams
/// ```
///
/// ## Complexity
///
/// - Time: O(n) where n is the byte count
/// - Space: O(n) for the returned set
@inlinable
internal func computeTrigrams(_ bytes: [UInt8]) -> Set<UInt32> {
    guard bytes.count >= 3 else { return [] }

    var trigrams = Set<UInt32>(minimumCapacity: bytes.count - 2)
    for i in 0..<(bytes.count - 2) {
        // Skip trigrams containing spaces — multi-word queries produce space trigrams
        // (e.g. "an ", "n s", " sa" from "goldman sachs") that won't match candidates
        // using different word separators (camelCase, snake_case). Filtering these out
        // lets us safely apply the trigram prefilter to multi-word queries.
        let a = bytes[i], b = bytes[i + 1], c = bytes[i + 2]
        if a == 0x20 || b == 0x20 || c == 0x20 { continue }
        let hash = trigramHash(a, b, c)
        trigrams.insert(hash)
    }
    return trigrams
}

/// Counts the number of trigrams in the candidate that match the query trigrams.
///
/// Computes candidate trigrams on the fly without allocating a set, checking
/// each against the precomputed query trigram set.
///
/// - Parameters:
///   - candidateBytes: The candidate bytes (lowercased UTF-8).
///   - queryTrigrams: The precomputed query trigrams from ``computeTrigrams(_:)``.
/// - Returns: The count of shared trigrams.
///
/// ## Performance
///
/// Computing trigrams on-the-fly avoids allocating a Set for each candidate,
/// reducing memory pressure in the hot path.
///
/// ## Complexity
///
/// - Time: O(candidateLength) for trigram generation, O(1) per lookup
/// - Space: O(1) - no allocation for candidate trigrams
@inlinable
internal func countSharedTrigrams(
    candidateBytes: UnsafeBufferPointer<UInt8>,
    queryTrigrams: Set<UInt32>
) -> Int {
    guard candidateBytes.count >= 3 else { return 0 }

    var sharedCount = 0
    for i in 0..<(candidateBytes.count - 2) {
        let a = candidateBytes[i], b = candidateBytes[i + 1], c = candidateBytes[i + 2]
        // Skip space-containing trigrams (see computeTrigrams for rationale)
        if a == 0x20 || b == 0x20 || c == 0x20 { continue }
        let hash = trigramHash(a, b, c)
        if queryTrigrams.contains(hash) {
            sharedCount += 1
        }
    }
    return sharedCount
}

/// Checks if a candidate passes the trigram prefilter.
///
/// For two strings to be within edit distance `d`, they must share at least
/// `queryTrigrams.count - 3 * d` trigrams (each edit can destroy up to 3 trigrams).
/// This check rejects candidates that differ too much from the query.
///
/// - Parameters:
///   - candidateBytes: The candidate bytes (lowercased UTF-8).
///   - queryTrigrams: The precomputed query trigrams.
///   - maxEditDistance: Maximum allowed edit distance.
/// - Returns: `true` if the candidate passes the trigram check.
///
/// ## Logic
///
/// ```
/// sharedCount = countSharedTrigrams(...)
/// minRequired = queryTrigrams.count - 3 * maxEditDistance
/// passes = sharedCount >= minRequired
/// ```
///
/// ## When Applied
///
/// Trigram filtering is only applied for queries with 4+ characters.
/// Shorter queries produce too few trigrams for effective filtering.
///
/// ## Complexity
///
/// O(candidateLength) - linear scan to compute candidate trigrams.
@inlinable
internal func passesTrigramFilter(
    candidateBytes: UnsafeBufferPointer<UInt8>,
    queryTrigrams: Set<UInt32>,
    maxEditDistance: Int
) -> Bool {
    guard !queryTrigrams.isEmpty else { return true }

    let sharedCount = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    // Each edit operation can destroy up to 3 trigrams (a transposition at position i
    // affects trigrams at i-2..i, i-1..i+1, and i..i+2). Use a factor of 3 to avoid
    // false rejections on Damerau-Levenshtein transposition typos.
    return sharedCount >= queryTrigrams.count - 3 * maxEditDistance
}
