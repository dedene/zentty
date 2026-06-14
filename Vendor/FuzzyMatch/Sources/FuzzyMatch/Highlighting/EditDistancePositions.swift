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

/// Computes Damerau-Levenshtein alignment positions for highlighting.
///
/// This is a full-matrix variant of ``substringEditDistance`` that retains the
/// complete DP table and traceback flags so matched/substituted positions can be
/// recovered. It is NOT used on the scoring hot path — only called for the small
/// number of visible results that need highlight ranges.
///
/// By default, the function operates in substring mode (free start: `cost[i][0] = 0`),
/// finding the best match anywhere within the candidate. When `prefixMode` is `true`,
/// the first column uses standard Levenshtein costs (`cost[i][0] = i`), anchoring the
/// alignment at position 0, and limits the candidate scan to `queryLen + maxEditDistance`.
///
/// - Parameters:
///   - query: Lowercased query bytes.
///   - candidate: Lowercased candidate bytes.
///   - maxEditDistance: Maximum allowed edit distance.
///   - prefixMode: When `true`, anchor the alignment at position 0 (prefix match).
/// - Returns: Sorted array of candidate byte positions to highlight, or nil
///   if no alignment within `maxEditDistance` is found.
///
/// ## Traceback semantics
///
/// Each candidate position in the returned array corresponds to a query
/// character that was either matched exactly or substituted:
///
/// | Operation     | Query char consumed | Candidate pos highlighted |
/// |---------------|:-------------------:|:------------------------:|
/// | Match         | yes                 | yes                      |
/// | Substitution  | yes                 | yes (shows where user "meant") |
/// | Deletion      | yes                 | no (extra query char)    |
/// | Insertion     | no                  | no (extra candidate char)|
/// | Transposition | 2                   | 2                        |
internal func editDistancePositions(
    query: UnsafeBufferPointer<UInt8>,
    candidate: UnsafeBufferPointer<UInt8>,
    maxEditDistance: Int,
    prefixMode: Bool = false
) -> [Int]? {
    let queryLen = query.count
    let candidateLen = prefixMode
        ? min(candidate.count, queryLen + maxEditDistance)
        : candidate.count
    guard queryLen > 0, candidateLen > 0 else { return nil }

    let cols = queryLen + 1
    let rows = candidateLen + 1

    // Full DP matrix and traceback flags
    var cost = [Int](repeating: 0, count: rows * cols)
    // Trace: 0=none, 1=match/sub (diagonal), 2=delete query char (left),
    //        3=skip candidate char (up), 4=transposition
    var trace = [UInt8](repeating: 0, count: rows * cols)

    // First row: cost[0][j] = j (delete j query chars to match empty candidate)
    for j in 1...queryLen {
        cost[j] = j
        trace[j] = 2
    }
    // First column: in prefix mode cost[i][0] = i (standard Levenshtein);
    // in substring mode cost[i][0] = 0 (free start at any position)
    if prefixMode {
        for i in 1...candidateLen {
            cost[i * cols] = i
            trace[i * cols] = 3
        }
    }

    for i in 1...candidateLen {
        let candidateChar = candidate[i - 1]

        for j in 1...queryLen {
            let queryChar = query[j - 1]
            let idx = i * cols + j

            let subCost = queryChar == candidateChar ? 0 : 1

            let diagonal = cost[(i - 1) * cols + (j - 1)] + subCost
            let skipCandidate = cost[(i - 1) * cols + j] + 1
            let deleteQuery = cost[i * cols + (j - 1)] + 1

            // Prefer: diagonal (match/sub) > skipCandidate > deleteQuery
            var best = diagonal
            var bestTrace: UInt8 = 1

            if skipCandidate < best {
                best = skipCandidate
                bestTrace = 3
            }
            if deleteQuery < best {
                best = deleteQuery
                bestTrace = 2
            }

            // Damerau transposition: swap adjacent characters
            if i > 1 && j > 1 {
                let prevCandidateChar = candidate[i - 2]
                let prevQueryChar = query[j - 2]

                if queryChar == prevCandidateChar && prevQueryChar == candidateChar {
                    let transposition = cost[(i - 2) * cols + (j - 2)] + 1
                    if transposition < best {
                        best = transposition
                        bestTrace = 4
                    }
                }
            }

            cost[idx] = best
            trace[idx] = bestTrace
        }
    }

    // Find best ending position (minimum cost[i][queryLen])
    var bestDist = Int.max
    var bestEnd = -1
    for i in 1...candidateLen {
        let dist = cost[i * cols + queryLen]
        if dist <= bestDist {
            bestDist = dist
            bestEnd = i
        }
    }

    guard bestDist <= maxEditDistance, bestEnd > 0 else { return nil }

    // Traceback: collect candidate positions that are highlighted
    var positions: [Int] = []
    var i = bestEnd
    var j = queryLen

    while j > 0 && i > 0 {
        let traceFlag = trace[i * cols + j]
        switch traceFlag {
        case 1: // match or substitution — highlight candidate[i-1]
            positions.append(i - 1)
            i -= 1
            j -= 1
        case 2: // delete query char (extra char in query, no candidate match)
            j -= 1
        case 3: // skip candidate char (extra char in candidate)
            i -= 1
        case 4: // transposition — highlight both swapped positions
            positions.append(i - 1)
            positions.append(i - 2)
            i -= 2
            j -= 2
        default:
            break
        }
    }

    guard !positions.isEmpty else { return nil }
    positions.sort()
    return positions
}
