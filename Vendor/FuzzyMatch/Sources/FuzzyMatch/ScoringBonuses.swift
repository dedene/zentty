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

/// Scoring bonus calculations for fuzzy matching.
///
/// This module provides functions to calculate scoring bonuses based on where
/// query characters align within candidate strings. Matches at word boundaries
/// and consecutive character matches receive bonuses, while gaps between matches
/// incur penalties.
///
/// ## Overview
///
/// The bonus system improves ranking quality by rewarding patterns that match
/// user expectations. For example, when typing "gubi", users expect "getUserById"
/// to rank higher than "debugging" because the query characters match at word
/// boundaries (g-et, U-ser, B-y, I-d).
///
/// ## Topics
///
/// ### Position Finding
/// - ``findMatchPositions(query:candidate:boundaryMask:positions:)``
///
/// ### Bonus Calculation
/// - ``calculateBonuses(matchPositions:positionCount:candidateBytes:boundaryMask:config:)``

/// Finds optimal positions where query characters match in the candidate.
///
/// Uses a greedy algorithm that prefers:
/// 1. Word boundary positions (camelCase, snake_case transitions)
/// 2. Consecutive positions (continuing a run of matches)
/// 3. First available position
///
/// - Parameters:
///   - query: The query bytes (lowercased UTF-8).
///   - candidate: The candidate bytes (lowercased UTF-8).
///   - boundaryMask: Precomputed word boundary bitmask for the candidate.
///   - positions: Output buffer to store match positions. Must have capacity >= query.count.
/// - Returns: The number of query characters successfully matched, or 0 if matching failed.
///
/// ## Algorithm
///
/// For each query character, scan forward in the candidate to find a matching position.
/// When multiple positions are available for the same character, prefer:
/// 1. A position that is a word boundary
/// 2. A position consecutive to the previous match
/// 3. The first available position
///
/// ## Complexity
///
/// O(n * m) worst case, but typically O(n + m) for well-matched strings where
/// n = query length, m = candidate length.
///
/// ## Example
///
/// ```swift
/// // Query: "gubi", Candidate: "getUserById"
/// // Returns positions: [0, 3, 7, 9] (g, U, B, I)
/// ```
@inlinable
internal func findMatchPositions(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    boundaryMask: UInt64,
    positions: inout [Int]
) -> Int {
    let queryLen = query.count
    let candidateLength = candidate.count
    guard queryLen > 0 && candidateLength > 0 else { return 0 }

    var candidateIndex = 0
    var positionCount = 0

    for queryIndex in 0..<queryLen {
        let queryChar = query[queryIndex]

        // Find the next matching character in candidate
        var bestPosition = -1
        var foundBoundary = false

        // Look ahead for a boundary match first (up to a reasonable distance)
        let searchLimit = min(candidateIndex + queryLen + 5, candidateLength)

        for searchPos in candidateIndex..<searchLimit {
            if candidate[searchPos] == queryChar {
                // Check if this is a word boundary
                let isBoundary: Bool
                if searchPos < 64 {
                    isBoundary = (boundaryMask & (1 << searchPos)) != 0
                } else {
                    isBoundary = isWordBoundary(at: searchPos, in: candidate)
                }

                if isBoundary {
                    bestPosition = searchPos
                    foundBoundary = true
                    break
                } else if bestPosition == -1 {
                    // Record first match as fallback
                    bestPosition = searchPos
                }
            }
        }

        // If no boundary found in look-ahead, check if we should prefer consecutive
        if !foundBoundary && bestPosition != -1 && positionCount > 0 {
            let prevPosition = positions[positionCount - 1]
            // If first match is consecutive, that's good enough
            if bestPosition == prevPosition + 1 {
                // Keep it
            } else {
                // See if there's a consecutive match we missed
                if prevPosition + 1 < candidateLength && candidate[prevPosition + 1] == queryChar {
                    bestPosition = prevPosition + 1
                }
            }
        }

        // If still no match in look-ahead, scan the rest of candidate
        if bestPosition == -1 {
            for searchPos in searchLimit..<candidateLength {
                if candidate[searchPos] == queryChar {
                    bestPosition = searchPos
                    break
                }
            }
        }

        // If we couldn't find this query character, matching failed
        if bestPosition == -1 {
            return 0
        }

        positions[positionCount] = bestPosition
        positionCount += 1
        candidateIndex = bestPosition + 1
    }

    return positionCount
}

/// Finds the optimal subsequence alignment using a two-state affine gap DP.
///
/// This function finds the alignment of query characters within the candidate that
/// maximizes the total bonus score. It considers word boundaries, consecutive matches,
/// and gap penalties simultaneously, avoiding the suboptimal results of the greedy approach.
///
/// For candidates > 512 bytes, falls back to the greedy `findMatchPositions` + `calculateBonuses`.
///
/// - Parameters:
///   - query: The query bytes (lowercased UTF-8).
///   - candidate: The candidate bytes (lowercased UTF-8).
///   - boundaryMask: Precomputed word boundary bitmask for the candidate.
///   - positions: Output buffer to store optimal match positions.
///   - state: Reusable alignment state buffers.
///   - config: Configuration containing bonus values and penalties.
/// - Returns: A tuple of (positionCount, bonus) or (0, 0.0) if no alignment found.
@inlinable
internal func optimalAlignment(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    boundaryMask: UInt64,
    positions: inout [Int],
    state: inout AlignmentState,
    config: EditDistanceConfig
) -> (positionCount: Int, bonus: Double) {
    let queryLen = query.count
    let candidateLen = candidate.count
    guard queryLen > 0, candidateLen > 0 else { return (0, 0.0) }

    // For large candidates, fall back to greedy
    if candidateLen > 512 {
        let positionCount = findMatchPositions(
            query: query, candidate: candidate,
            boundaryMask: boundaryMask, positions: &positions
        )
        if positionCount == 0 { return (0, 0.0) }
        let bonus = calculateBonuses(
            matchPositions: positions, positionCount: positionCount,
            candidateBytes: candidate, boundaryMask: boundaryMask, config: config
        )
        return (positionCount, bonus)
    }

    state.ensureCapacity(queryLength: queryLen, candidateLength: candidateLen)

    // Gap penalty values
    let gapOpenPenalty: Double
    let gapExtendPenalty: Double
    switch config.gapPenalty {
    case .none:
        gapOpenPenalty = 0.0
        gapExtendPenalty = 0.0
    case .linear(let perChar):
        gapOpenPenalty = perChar
        gapExtendPenalty = perChar
    case .affine(let open, let extend):
        gapOpenPenalty = open
        gapExtendPenalty = extend
    }

    // We use two full matrices (candidateLen × queryLen) stored flat:
    //   matchScore[i * queryLen + j] = best score with query[j] matched at candidate[i] (consecutive)
    //   gapScore[i * queryLen + j]   = best score with query[j] matched earlier, gap to candidate[i]
    // The traceback stores which state each match came from.

    let matSize = candidateLen * queryLen

    // Reuse traceback array for the match score matrix too (we need 3 matrices total)
    // For simplicity, use the state arrays sized for single rows during forward pass,
    // but store match scores in a full matrix for traceback.

    // Stack-allocate match/gap matrices via withUnsafeTemporaryAllocation.
    // For small matSize the runtime uses the stack; for larger sizes it falls back to heap.
    return withUnsafeTemporaryAllocation(of: Double.self, capacity: matSize) { matchBuf in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: matSize) { gapBuf in
            matchBuf.initialize(repeating: -.infinity)
            gapBuf.initialize(repeating: -.infinity)

            // Traceback: 0 = no match, 1 = from consecutive match, 2 = from gap
            for idx in 0..<matSize {
                state.traceback[idx] = 0
            }

            var bestEndScore: Double = -.infinity
            var bestEndCandidatePos: Int = -1
            var bestEndFromMatch = false

            // Forward pass
            for i in 0..<candidateLen {
                let candidateChar = candidate[i]

                let isBoundary: Bool
                if i < 64 {
                    isBoundary = (boundaryMask & (1 << i)) != 0
                } else {
                    isBoundary = isWordBoundary(at: i, in: candidate)
                }
                let bBonus = isBoundary ? config.wordBoundaryBonus : 0.0

                for j in 0..<queryLen {
                    let idx = i * queryLen + j

                    // Gap transition: query[j] was matched at some i' < i, now we're at i without matching
                    if i > 0 {
                        let prevIdx = (i - 1) * queryLen + j
                        var newGap: Double = -.infinity
                        let prevMatch = matchBuf[prevIdx]
                        if prevMatch.isFinite {
                            newGap = prevMatch - gapOpenPenalty
                        }
                        let prevGap = gapBuf[prevIdx]
                        if prevGap.isFinite {
                            newGap = max(newGap, prevGap - gapExtendPenalty)
                        }
                        gapBuf[idx] = newGap
                    }

                    // Match transition: candidate[i] == query[j]
                    if candidateChar == query[j] {
                        var newMatch: Double = -.infinity
                        var traceFlag: UInt8 = 0

                        if j == 0 {
                            // First query char matched here
                            newMatch = bBonus
                            traceFlag = 2 // from gap (no predecessor)
                        } else if i > 0 {
                            let prevIdx = (i - 1) * queryLen + (j - 1)
                            // From consecutive match at (i-1, j-1)
                            let prevMatch = matchBuf[prevIdx]
                            if prevMatch.isFinite {
                                let fromConsecutive = prevMatch + config.consecutiveBonus + bBonus
                                if fromConsecutive > newMatch {
                                    newMatch = fromConsecutive
                                    traceFlag = 1 // from consecutive
                                }
                            }
                            // From gap at (i-1, j-1)
                            let prevGap = gapBuf[prevIdx]
                            if prevGap.isFinite {
                                let fromGap = prevGap + bBonus
                                if fromGap > newMatch {
                                    newMatch = fromGap
                                    traceFlag = 2 // from gap
                                }
                            }
                        }

                        matchBuf[idx] = newMatch
                        state.traceback[idx] = traceFlag

                        // Track best complete alignment
                        if j == queryLen - 1 && newMatch > bestEndScore {
                            bestEndScore = newMatch
                            bestEndCandidatePos = i
                            bestEndFromMatch = true
                        }
                    }

                    // Also check gap completion
                    if j == queryLen - 1 && gapBuf[idx] > bestEndScore {
                        bestEndScore = gapBuf[idx]
                        bestEndCandidatePos = i
                        bestEndFromMatch = false
                    }
                }
            }

            if !bestEndScore.isFinite {
                return (0, 0.0)
            }

            // Traceback: recover optimal positions
            var j = queryLen - 1
            var i = bestEndCandidatePos
            if !bestEndFromMatch {
                while i >= 0 {
                    if matchBuf[i * queryLen + j].isFinite && state.traceback[i * queryLen + j] != 0 {
                        break
                    }
                    i -= 1
                }
                if i < 0 { return (0, 0.0) }
            }

            positions[j] = i
            while j > 0 {
                let trace = state.traceback[i * queryLen + j]
                if trace == 1 {
                    i -= 1
                    j -= 1
                } else {
                    i -= 1
                    j -= 1
                    while i >= 0 {
                        let idx = i * queryLen + j
                        if matchBuf[idx].isFinite && state.traceback[idx] != 0 {
                            break
                        }
                        if gapBuf[idx].isFinite && i > 0 {
                            i -= 1
                            continue
                        }
                        i -= 1
                    }
                    if i < 0 { return (0, 0.0) }
                }
                positions[j] = i
            }

            // Apply first match bonus
            var bonus = bestEndScore
            if config.firstMatchBonus > 0 {
                let firstPos = positions[0]
                if firstPos < config.firstMatchBonusRange {
                    let decay = 1.0 - (Double(firstPos) / Double(config.firstMatchBonusRange))
                    bonus += config.firstMatchBonus * decay
                }
            }

            return (queryLen, bonus)
        }
    }
}

/// Calculates scoring bonuses based on match positions.
///
/// Applies several types of score adjustments:
/// - **Word boundary bonus**: Added when a query character matches at a word boundary
/// - **Consecutive bonus**: Added when query characters match consecutive positions
/// - **Gap penalty**: Subtracted for gaps between matched characters (see ``GapPenalty``)
/// - **First match bonus**: Added based on how early the first match appears
///
/// - Parameters:
///   - matchPositions: Array of positions where query characters matched in the candidate.
///   - positionCount: The number of valid positions in the array.
///   - candidateBytes: The candidate bytes (lowercased UTF-8).
///   - boundaryMask: Precomputed word boundary bitmask for the candidate.
///   - config: Configuration containing bonus values and penalties.
/// - Returns: The total bonus value to add to the base score.
///
/// ## Calculation
///
/// ```
/// bonus = 0
/// for each match position:
///     if position is word boundary: bonus += wordBoundaryBonus
///     if position is consecutive: bonus += consecutiveBonus
///     else if gap exists: bonus -= gapPenalty(gap)
/// if first match is early: bonus += firstMatchBonus * decay
/// ```
///
/// ## Example
///
/// ```swift
/// // Query "gubi" matching "getUserById" at positions [0, 3, 7, 9]
/// // Position 0: boundary bonus (start of string)
/// // Position 3: boundary bonus (U in User), gap penalty for 2 chars
/// // Position 7: boundary bonus (B in By), gap penalty for 3 chars
/// // Position 9: boundary bonus (I in Id), gap penalty for 1 char
/// // Plus first match bonus (position 0 gets full bonus)
/// ```
@inlinable
internal func calculateBonuses(
    matchPositions: [Int],
    positionCount: Int,
    candidateBytes: UnsafeBufferPointer<UInt8>,
    boundaryMask: UInt64,
    config: EditDistanceConfig
) -> Double {
    guard positionCount > 0 else { return 0.0 }

    var bonus: Double = 0.0
    var previousPosition: Int = -2  // -2 so first match isn't "consecutive"

    for i in 0..<positionCount {
        let candidatePosition = matchPositions[i]

        // Word boundary bonus
        let isBoundary: Bool
        if candidatePosition < 64 {
            isBoundary = (boundaryMask & (1 << candidatePosition)) != 0
        } else {
            isBoundary = isWordBoundary(at: candidatePosition, in: candidateBytes)
        }

        if isBoundary {
            bonus += config.wordBoundaryBonus
        }

        // Consecutive match bonus
        if candidatePosition == previousPosition + 1 {
            bonus += config.consecutiveBonus
        } else if i > 0 && candidatePosition > previousPosition + 1 {
            // Gap penalty (for non-consecutive matches after the first)
            let gap = candidatePosition - previousPosition - 1
            switch config.gapPenalty {
            case .none:
                break
            case .linear(let perCharacter):
                bonus -= Double(gap) * perCharacter
            case .affine(let open, let extend):
                // Affine: opening penalty + extension penalty per additional character
                bonus -= open + Double(gap - 1) * extend
            }
        }

        previousPosition = candidatePosition
    }

    // Position-based bonus: reward matches starting early in the candidate
    if config.firstMatchBonus > 0 {
        let firstPos = matchPositions[0]
        if firstPos < config.firstMatchBonusRange {
            // Linear decay: full bonus at 0, zero bonus at firstMatchBonusRange
            let decay = 1.0 - (Double(firstPos) / Double(config.firstMatchBonusRange))
            bonus += config.firstMatchBonus * decay
        }
    }

    return bonus
}

/// Scans the candidate for a contiguous byte-exact occurrence of the query.
///
/// When `findMatchPositions` returns scattered positions for a short query that
/// has an exact substring match (distance == 0), this function finds the actual
/// contiguous occurrence so that consecutive and boundary bonuses apply correctly.
///
/// Prefers a whole-word-bounded match (word boundary at start and non-alphanumeric
/// or end-of-string after the match). Falls back to the first contiguous occurrence.
///
/// - Parameters:
///   - query: The query bytes (lowercased UTF-8).
///   - candidate: The candidate bytes (lowercased UTF-8).
///   - boundaryMask: Precomputed word boundary bitmask for the candidate.
/// - Returns: The start index of the best contiguous match, or -1 if none found.
@inlinable
internal func findContiguousSubstring(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    boundaryMask: UInt64
) -> Int {
    let qLen = query.count
    let cLen = candidate.count
    guard qLen > 0, qLen <= cLen else { return -1 }

    var firstMatch = -1

    for startPos in 0...(cLen - qLen) {
        var matches = true
        for i in 0..<qLen {
            if candidate[startPos + i] != query[i] {
                matches = false
                break
            }
        }
        guard matches else { continue }
        if firstMatch < 0 { firstMatch = startPos }

        // Prefer whole-word bounded match
        let startBound = isWordBoundary(at: startPos, in: candidate)
        let endPos = startPos + qLen
        let endBound: Bool
        if endPos >= cLen {
            endBound = true
        } else {
            let b = candidate[endPos]
            let isAlphaNum = (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
            endBound = !isAlphaNum
        }
        if startBound && endBound { return startPos }
    }
    return firstMatch
}
