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

/// Edit distance implementation using the Damerau-Levenshtein algorithm.
///
/// This module provides the core edit distance computation used by ``FuzzyMatcher``.
/// The Damerau-Levenshtein algorithm extends classic Levenshtein distance by also
/// counting transpositions (swapping adjacent characters) as a single edit.
///
/// ## Supported Edit Operations
///
/// | Operation | Example | Cost |
/// |-----------|---------|------|
/// | Insertion | "cat" → "cart" | 1 |
/// | Deletion | "cart" → "cat" | 1 |
/// | Substitution | "cat" → "bat" | 1 |
/// | Transposition | "teh" → "the" | 1 |
///
/// ## See Also
///
/// - ``prefixEditDistance(query:candidate:state:maxEditDistance:)``
/// - ``substringEditDistance(query:candidate:state:maxEditDistance:)``
/// - ``normalizedScore(editDistance:queryLength:kind:config:)``

/// Computes the prefix edit distance (Damerau-Levenshtein) between query and the start of candidate.
///
/// This function finds the minimum number of edits needed to transform the query into
/// a prefix of the candidate string. The candidate may have additional trailing characters
/// that are ignored.
///
/// - Parameters:
///   - query: The query bytes (lowercased UTF-8).
///   - candidate: The candidate bytes (lowercased UTF-8).
///   - state: The edit distance state containing DP row arrays.
///   - maxEditDistance: Early exit threshold. Returns `nil` if distance exceeds this.
/// - Returns: The minimum prefix edit distance, or `nil` if it exceeds `maxEditDistance`.
///
/// ## Algorithm
///
/// Uses dynamic programming with a rolling array technique:
/// 1. Initialize DP row with costs 0, 1, 2, ..., queryLength
/// 2. For each character in candidate (up to prefix limit):
///    - Compute costs for insertion, deletion, substitution
///    - Check for transposition (adjacent character swap)
///    - Track minimum complete match distance
/// 3. Return best distance if within threshold
///
/// ## Complexity
///
/// - Time: O(queryLength × min(candidateLength, queryLength + maxEditDistance))
/// - Space: O(queryLength) using rolling arrays
///
/// ## Example
///
/// ```swift
/// // "get" matching prefix of "getUserById"
/// // Distance: 0 (exact prefix match)
///
/// // "tge" matching prefix of "getUserById"
/// // Distance: 1 (transposition: tge → get)
/// ```
@inlinable
internal func prefixEditDistance(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    state: inout EditDistanceState,
    maxEditDistance: Int
) -> Int? {
    let candidateLength = candidate.count
    let queryLen = query.count

    // Handle empty query - 0 edits needed for empty prefix
    guard queryLen > 0 else { return 0 }

    // For prefix matching, we want to find minimum edits to match query against
    // the beginning of candidate. We compute standard edit distance but track
    // the best complete match (row[queryLen]) at each position.

    // Initialize first row (cost to transform empty string to query prefix)
    for j in 0...queryLen {
        state.row[j] = j
        state.prevRow[j] = j
        state.prevPrevRow[j] = j
    }

    var bestDistance = queryLen  // Start with worst case (all insertions)

    // Process each character in candidate (but only up to a reasonable prefix)
    let prefixLimit = min(candidateLength, queryLen + maxEditDistance)

    for i in 0..<prefixLimit {
        // Rotate rows (O(1) pointer exchange, no COW copies)
        state.rotateRows()

        state.row[0] = i + 1  // Cost to delete i+1 characters from candidate

        let candidateChar = candidate[i]

        for j in 1...queryLen {
            let queryChar = query[j - 1]

            let substitutionCost = queryChar == candidateChar ? 0 : 1

            // Standard Levenshtein operations
            let deletion = state.row[j - 1] + 1
            let insertion = state.prevRow[j] + 1
            let substitution = state.prevRow[j - 1] + substitutionCost

            var cost = min(deletion, min(insertion, substitution))

            // Damerau transposition: check if we can swap adjacent characters
            if i > 0 && j > 1 {
                let prevCandidateChar = candidate[i - 1]
                let prevQueryChar = query[j - 2]

                if queryChar == prevCandidateChar && prevQueryChar == candidateChar {
                    let transposition = state.prevPrevRow[j - 2] + 1
                    cost = min(cost, transposition)
                }
            }

            state.row[j] = cost
        }

        // Track best complete match of the entire query
        if state.row[queryLen] < bestDistance {
            bestDistance = state.row[queryLen]
        }

        // Early exit if we found an exact prefix match
        if bestDistance == 0 {
            return 0
        }

        // Row-minimum pruning: if the smallest value in the current row exceeds
        // maxEditDistance + remaining columns, no future column can produce a valid result.
        // Each remaining column can decrease the row minimum by at most 1 (via a diagonal match).
        let remaining = prefixLimit - i - 1
        if remaining > 0 {
            var rowMin = state.row[1]
            if queryLen >= 2 {
                for j in 2...queryLen {
                    if state.row[j] < rowMin { rowMin = state.row[j] }
                }
            }
            if rowMin > maxEditDistance + remaining {
                break
            }
        }
    }

    if bestDistance > maxEditDistance {
        return nil
    }

    return bestDistance
}

/// Computes the best substring edit distance using a modified DP approach.
///
/// This function finds the minimum number of edits needed to match the query
/// anywhere within the candidate string (not just at the beginning).
///
/// - Parameters:
///   - query: The query bytes (lowercased UTF-8).
///   - candidate: The candidate bytes (lowercased UTF-8).
///   - state: The edit distance state containing DP arrays.
///   - maxEditDistance: Early exit threshold.
/// - Returns: The minimum substring edit distance, or `nil` if no good match found.
///
/// ## Algorithm
///
/// Similar to prefix edit distance, but with a key modification:
/// - Set `row[0] = 0` at each position (free to start matching anywhere)
/// - This allows the match to "begin fresh" at any position in the candidate
///
/// ## Complexity
///
/// - Time: O(queryLength × candidateLength)
/// - Space: O(queryLength) using rolling arrays
///
/// ## Example
///
/// ```swift
/// // "user" matching anywhere in "getCurrentUser"
/// // Distance: 0 (exact substring match at position 10)
/// ```
@inlinable
internal func substringEditDistance(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    state: inout EditDistanceState,
    maxEditDistance: Int
) -> Int? {
    let candidateLength = candidate.count
    let queryLen = query.count

    guard queryLen > 0 && candidateLength > 0 else { return nil }

    // We use a modified edit distance where we can start matching anywhere
    // This is achieved by setting row[0] = 0 at each position (free start)

    // Initialize
    for j in 0...queryLen {
        state.row[j] = j
        state.prevRow[j] = j
        state.prevPrevRow[j] = j
    }

    var bestDistance = Int.max

    for i in 0..<candidateLength {
        // Rotate rows (O(1) pointer exchange, no COW copies)
        state.rotateRows()

        state.row[0] = 0  // Free to start matching at any position

        let candidateChar = candidate[i]

        for j in 1...queryLen {
            let queryChar = query[j - 1]

            let substitutionCost = queryChar == candidateChar ? 0 : 1

            let deletion = state.row[j - 1] + 1
            let insertion = state.prevRow[j] + 1
            let substitution = state.prevRow[j - 1] + substitutionCost

            var cost = min(deletion, min(insertion, substitution))

            // Damerau transposition
            if i > 0 && j > 1 {
                let prevCandidateChar = candidate[i - 1]
                let prevQueryChar = query[j - 2]

                if queryChar == prevCandidateChar && prevQueryChar == candidateChar {
                    let transposition = state.prevPrevRow[j - 2] + 1
                    cost = min(cost, transposition)
                }
            }

            state.row[j] = cost
        }

        // Track best complete match (all of query matched)
        if state.row[queryLen] < bestDistance {
            bestDistance = state.row[queryLen]
            // Early exit on exact substring match — no need to scan remaining candidate
            if bestDistance == 0 {
                return 0
            }
        }
    }

    if bestDistance > maxEditDistance {
        return nil
    }

    return bestDistance
}

/// Computes a normalized score from edit distance.
///
/// Converts the raw edit distance into a score between 0.0 and 1.0, applying
/// match type weighting from the configuration.
///
/// - Parameters:
///   - editDistance: The computed edit distance.
///   - queryLength: The length of the query in bytes.
///   - kind: The kind of match (prefix or substring).
///   - config: The match configuration containing weights.
/// - Returns: A normalized score between 0.0 and 1.0.
///
/// ## Calculation
///
/// ```
/// baseScore = 1.0 - (editDistance / queryLength)
/// weight = prefixWeight or substringWeight (based on kind)
/// finalScore = max(0, 1.0 - (1.0 - baseScore) / weight)
/// ```
///
/// The asymptotic formula preserves 1.0 for perfect matches (distance=0) regardless
/// of weight, while still boosting near-matches. This ensures that a perfect prefix
/// always scores strictly higher than a transposed prefix.
///
/// ## Example
///
/// ```swift
/// // editDistance: 1, queryLength: 5, prefix match, prefixWeight: 1.5
/// // baseScore = 1.0 - (1/5) = 0.8
/// // finalScore = max(0, 1.0 - 0.2/1.5) ≈ 0.867
/// ```
@inlinable
internal func normalizedScore(
    editDistance: Int,
    queryLength: Int,
    kind: MatchKind,
    config: EditDistanceConfig
) -> Double {
    let base = max(0, 1.0 - (Double(editDistance) / Double(max(queryLength, 1))))
    let weight = kind == .prefix ? config.prefixWeight : config.substringWeight
    return max(0.0, 1.0 - (1.0 - base) / weight)
}
