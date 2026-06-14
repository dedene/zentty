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

/// Computes Smith-Waterman alignment positions for highlighting.
///
/// This is a traceback variant of ``smithWatermanScore`` that retains the full
/// DP matrices so matched positions can be recovered. It is NOT used on the
/// scoring hot path — only called for the small number of visible results
/// that need highlight ranges.
///
/// - Parameters:
///   - query: Lowercased query bytes.
///   - candidate: Lowercased candidate bytes.
///   - bonus: Precomputed per-position bonus values.
///   - config: Smith-Waterman scoring constants.
/// - Returns: Array of matched normalized byte positions (one per query char),
///   or nil if no alignment found. The positions are not guaranteed to be sorted.
internal func smithWatermanPositions(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    bonus: UnsafeBufferPointer<Int32>,
    config: SmithWatermanConfig
) -> [Int]? {
    let queryLen = query.count
    let candidateLen = candidate.count
    guard queryLen > 0, candidateLen > 0 else { return nil }

    let bonusBoundary = Int32(config.bonusBoundary)
    let bonusConsecutive = Int32(config.bonusConsecutive)
    let scoreMatch = Int32(config.scoreMatch)
    let penaltyGapStart = Int32(config.penaltyGapStart)
    let penaltyGapExtend = Int32(config.penaltyGapExtend)
    let firstCharMultiplier = Int32(config.bonusFirstCharMultiplier)

    let matSize = candidateLen * queryLen

    // Allocate full matrices for traceback
    var matchMat = [Int32](repeating: 0, count: matSize)
    var gapMat = [Int32](repeating: 0, count: matSize)
    var bonusMat = [Int32](repeating: 0, count: matSize)
    // Traceback: 0 = no match, 1 = from consecutive, 2 = from gap/start
    var trace = [UInt8](repeating: 0, count: matSize)

    var bestScore: Int32 = 0
    var bestEndPos: Int = -1
    var bestEndFromMatch = false

    // Forward pass — uses full matrices so we read diagonals directly
    // rather than the scalar-carry pattern used by the hot-path scorer.
    for i in 0..<candidateLen {
        let candidateChar = candidate[i]
        let posBonus = bonus[i]

        for j in 0..<queryLen {
            let idx = i * queryLen + j

            // Gap transition: M[i-1,j] and G[i-1,j]
            var newGap: Int32 = 0
            if i > 0 {
                let prevIdx = (i - 1) * queryLen + j
                let prevMatch = matchMat[prevIdx]
                if prevMatch > penaltyGapStart {
                    newGap = prevMatch - penaltyGapStart
                }
                let prevGap = gapMat[prevIdx]
                if prevGap > penaltyGapExtend {
                    let fromGap = prevGap - penaltyGapExtend
                    if fromGap > newGap { newGap = fromGap }
                }
            }
            gapMat[idx] = newGap

            // Match transition: uses diagonal M[i-1,j-1] and G[i-1,j-1]
            if candidateChar == query[j] {
                var newMatch: Int32 = 0
                var newBonus: Int32 = 0
                var traceFlag: UInt8 = 0

                if j == 0 {
                    newMatch = scoreMatch + posBonus * firstCharMultiplier
                    newBonus = posBonus
                    traceFlag = 2
                } else if i > 0 {
                    let diagIdx = (i - 1) * queryLen + (j - 1)
                    let diagM = matchMat[diagIdx]
                    let diagG = gapMat[diagIdx]
                    let diagB = bonusMat[diagIdx]

                    // Consecutive path (from diagM)
                    if diagM > 0 {
                        var carriedBonus = max(diagB, bonusConsecutive)
                        if posBonus >= bonusBoundary && posBonus > carriedBonus {
                            carriedBonus = posBonus
                        }
                        let effectiveBonus = max(carriedBonus, posBonus)
                        let fromConsecutive = diagM + scoreMatch + effectiveBonus
                        if fromConsecutive > newMatch {
                            newMatch = fromConsecutive
                            newBonus = carriedBonus
                            traceFlag = 1
                        }
                    }
                    // Gap-to-match path (from diagG)
                    if diagG > 0 {
                        let fromGap = diagG + scoreMatch + posBonus
                        if fromGap > newMatch {
                            newMatch = fromGap
                            newBonus = posBonus
                            traceFlag = 2
                        }
                    }
                }

                matchMat[idx] = newMatch
                bonusMat[idx] = newBonus
                trace[idx] = traceFlag

                // Track best complete alignment (last query char)
                if j == queryLen - 1 && newMatch > bestScore {
                    bestScore = newMatch
                    bestEndPos = i
                    bestEndFromMatch = true
                }
            } else {
                matchMat[idx] = 0
                bonusMat[idx] = 0
            }

            // Also check gap completion for last query char
            if j == queryLen - 1 && newGap > bestScore {
                bestScore = newGap
                bestEndPos = i
                bestEndFromMatch = false
            }
        }
    }

    guard bestScore > 0, bestEndPos >= 0 else { return nil }

    // Traceback: recover positions
    var positions = [Int](repeating: 0, count: queryLen)
    var j = queryLen - 1
    var i = bestEndPos

    // If best ended in gap state, find last match position for last query char
    if !bestEndFromMatch {
        while i >= 0 {
            let idx = i * queryLen + j
            if matchMat[idx] > 0 && trace[idx] != 0 {
                break
            }
            i -= 1
        }
        if i < 0 { return nil }
    }

    positions[j] = i
    while j > 0 {
        let traceFlag = trace[i * queryLen + j]
        if traceFlag == 1 {
            // Consecutive: came from (i-1, j-1)
            i -= 1
            j -= 1
        } else {
            // Gap: came from some (i', j-1) where i' < i
            i -= 1
            j -= 1
            while i >= 0 {
                let idx = i * queryLen + j
                if matchMat[idx] > 0 && trace[idx] != 0 {
                    break
                }
                i -= 1
            }
            if i < 0 { return nil }
        }
        positions[j] = i
    }

    return positions
}
