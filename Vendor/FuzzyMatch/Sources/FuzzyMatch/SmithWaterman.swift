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

/// Smith-Waterman local alignment scorer for fuzzy matching.
///
/// Implements a bonus-driven scoring approach inspired by nucleo. Each matched character
/// earns ``SmithWatermanConfig/scoreMatch`` points, with additional rewards for word
/// boundaries, camelCase transitions, and consecutive runs, minus affine gap penalties.
///
/// The DP uses three states (match, gap, and consecutiveBonus) backed by a single flat
/// `[Int32]` buffer with 3 rows. Diagonal values from the previous outer iteration are
/// carried as scalar variables, eliminating the need for row swaps or extra buffer rows.
/// All arithmetic is Int32-only in the inner loop; normalization to 0.0–1.0 happens afterward.
/// A zero-floor convention is used: 0 means "no valid state" and all valid scores are > 0.
///
/// ## Consecutive Bonus Propagation
///
/// When characters match consecutively at a word boundary, the boundary bonus is
/// carried forward through the entire consecutive run (nucleo-style). This makes
/// boundary-aligned runs significantly more valuable than scattered boundary matches:
///
/// ```
/// Query "bar" in "foo_bar":
///   'b' at boundary: bonus = 8 (boundary), carried = 8
///   'a' consecutive:  effective = max(carried=8, posBonus=0) = 8
///   'r' consecutive:  effective = max(carried=8, posBonus=0) = 8
/// ```

/// Computes the Smith-Waterman local alignment score for a query against a candidate.
///
/// - Parameters:
///   - query: Lowercased query bytes.
///   - candidate: Lowercased candidate bytes.
///   - bonus: Precomputed per-position bonus values (tiered boundary, camelCase, or 0).
///   - state: Reusable DP state buffers.
///   - config: Smith-Waterman scoring constants.
/// - Returns: The raw Int32 alignment score, or 0 if no alignment found.
@inlinable
func smithWatermanScore(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    bonus: UnsafeBufferPointer<Int32>,
    state: inout SmithWatermanState,
    config: SmithWatermanConfig
) -> Int32 {
    let queryLen = query.count
    let candidateLen = candidate.count
    guard queryLen > 0, candidateLen > 0 else { return 0 }

    state.ensureCapacity(queryLen)

    let bonusBoundary = Int32(config.bonusBoundary)
    let bonusConsecutive = Int32(config.bonusConsecutive)
    let scoreMatch = Int32(config.scoreMatch)
    let penaltyGapStart = Int32(config.penaltyGapStart)
    let penaltyGapExtend = Int32(config.penaltyGapExtend)
    let firstCharMultiplier = Int32(config.bonusFirstCharMultiplier)
    let lastQueryIdx = queryLen - 1

    // 3-row layout: [match row | gap row | bonus row], each queryLen wide
    let matchOff = 0
    let gapOff = queryLen
    let bonusOff = queryLen * 2

    var bestScore: Int32 = 0

    return state.buffer.withUnsafeMutableBufferPointer { buf in
        // Zero all three rows
        for j in 0..<queryLen {
            buf[matchOff + j] = 0
            buf[gapOff + j] = 0
            buf[bonusOff + j] = 0
        }

        // Forward pass: scan candidate positions, update DP rows in-place
        for i in 0..<candidateLen {
            let candidateChar = candidate[i]
            let posBonus = bonus[i]

            // Scalar diagonal carries from previous j iteration
            var diagMatch: Int32 = 0   // M[i-1, j-1]
            var diagGap: Int32 = 0     // G[i-1, j-1]
            var diagBonus: Int32 = 0   // B[i-1, j-1] (carried consecutive bonus)

            // DP inner loop — left-to-right with scalar diagonal carry
            for j in 0..<queryLen {
                // Save old values before overwriting (these are M[i-1,j], G[i-1,j], B[i-1,j])
                let oldMatch = buf[matchOff + j]
                let oldGap = buf[gapOff + j]
                let oldBonus = buf[bonusOff + j]

                // Gap transition: uses oldMatch (= M[i-1,j]) and oldGap (= G[i-1,j])
                var newGap: Int32 = 0
                if oldMatch > penaltyGapStart {
                    newGap = oldMatch - penaltyGapStart
                }
                if oldGap > penaltyGapExtend {
                    let fromGap = oldGap - penaltyGapExtend
                    if fromGap > newGap {
                        newGap = fromGap
                    }
                }
                buf[gapOff + j] = newGap

                // Match transition: uses diagMatch/diagGap/diagBonus (= values at [i-1,j-1])
                if candidateChar == query[j] {
                    var newMatch: Int32
                    var newBonus: Int32 = 0

                    if j == 0 {
                        newMatch = scoreMatch + posBonus * firstCharMultiplier
                        newBonus = posBonus  // start consecutive run with this bonus
                    } else {
                        newMatch = 0

                        // Consecutive match path (from diagMatch = M[i-1,j-1])
                        if diagMatch > 0 {
                            // nucleo-style consecutive bonus carry:
                            // 1. Upgrade to at least bonusConsecutive
                            var carriedBonus = max(diagBonus, bonusConsecutive)
                            // 2. If current position has a strong boundary (>= bonusBoundary),
                            //    upgrade the carried bonus to the position bonus
                            if posBonus >= bonusBoundary && posBonus > carriedBonus {
                                carriedBonus = posBonus
                            }
                            // 3. Effective bonus = max(carried, position)
                            let effectiveBonus = max(carriedBonus, posBonus)
                            let fromConsecutive = diagMatch + scoreMatch + effectiveBonus
                            if fromConsecutive > newMatch {
                                newMatch = fromConsecutive
                                newBonus = carriedBonus
                            }
                        }

                        // Gap-to-match path (from diagGap = G[i-1,j-1])
                        if diagGap > 0 {
                            let fromGap = diagGap + scoreMatch + posBonus
                            if fromGap > newMatch {
                                newMatch = fromGap
                                newBonus = posBonus  // new run starts with this bonus
                            }
                        }
                    }

                    buf[matchOff + j] = newMatch
                    buf[bonusOff + j] = newBonus
                } else {
                    buf[matchOff + j] = 0
                    buf[bonusOff + j] = 0
                }

                // Carry old values as diagonal for next j iteration
                diagMatch = oldMatch
                diagGap = oldGap
                diagBonus = oldBonus
            }

            // Track best score from the last query column (after inner loop)
            let lastMatch = buf[matchOff + lastQueryIdx]
            let lastGap = buf[gapOff + lastQueryIdx]
            if lastMatch > bestScore { bestScore = lastMatch }
            if lastGap > bestScore { bestScore = lastGap }
        }

        return bestScore
    }
}

/// Computes the position bonus for a multi-byte character in the merged lowercase+bonus pass.
///
/// Position 0 always gets ``bonusBoundaryWhitespace``; subsequent positions delegate
/// to ``multiByteBonusTier`` which inspects `prevByte` for the appropriate tier.
@inlinable
func multiBytePositionBonus(
    outIdx: Int,
    prevByte: UInt8,
    bonusBoundaryVal: Int32,
    bonusBoundaryWhitespaceVal: Int32,
    bonusBoundaryDelimiterVal: Int32
) -> Int32 {
    outIdx == 0
        ? bonusBoundaryWhitespaceVal
        : multiByteBonusTier(
            prevByte: prevByte,
            bonusBoundary: bonusBoundaryVal,
            bonusBoundaryWhitespace: bonusBoundaryWhitespaceVal,
            bonusBoundaryDelimiter: bonusBoundaryDelimiterVal
        )
}

/// Computes the tiered boundary bonus for a multi-byte character position.
///
/// Used by the slow path (Latin Extended, Greek, Cyrillic) where the current
/// character is always a letter (word char), so only `prevByte` determines the tier.
@inlinable
func multiByteBonusTier(
    prevByte: UInt8,
    bonusBoundary: Int32,
    bonusBoundaryWhitespace: Int32,
    bonusBoundaryDelimiter: Int32
) -> Int32 {
    let prevIsWhitespace = prevByte == 0x20 || prevByte == 0x09
    if prevIsWhitespace {
        return bonusBoundaryWhitespace
    }
    if prevByte == 0x2F || prevByte == 0x3A || prevByte == 0x3B || prevByte == 0x7C {
        return bonusBoundaryDelimiter
    }
    let prevIsAlnum = (prevByte >= 0x41 && prevByte <= 0x5A)
        || (prevByte >= 0x61 && prevByte <= 0x7A)
        || (prevByte >= 0x30 && prevByte <= 0x39)
        || prevByte == 0xC3
        || prevByte == 0xCE || prevByte == 0xCF
        || prevByte == 0xD0 || prevByte == 0xD1
        || (prevByte >= 0x80 && prevByte <= 0xBF)
    return (prevIsAlnum || prevIsWhitespace) ? 0 : bonusBoundary
}
