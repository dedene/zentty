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

extension FuzzyMatcher {
    // MARK: - Smith-Waterman Orchestrator

    /// Smith-Waterman scoring implementation.
    ///
    /// Orchestrates the SW scoring pipeline:
    /// 1. Bitmask prefilter (tolerance 0 — any missing character rejects)
    /// 2. Lowercase candidate
    /// 3. Exact match early exit
    /// 4. Compute boundary mask
    /// 5. Run Smith-Waterman DP
    /// 6. Normalize raw score to 0.0–1.0
    /// 7. Apply minScore threshold
    @inlinable
    internal func scoreSmithWatermanImpl(
        _ candidateUTF8: UnsafeBufferPointer<UInt8>,
        against query: FuzzyQuery,
        swConfig: SmithWatermanConfig,
        candidateStorage: inout CandidateStorage,
        smithWatermanState: inout SmithWatermanState,
        wordInitials: inout [UInt8]
    ) -> ScoredMatch? {
        let candidateLength = candidateUTF8.count
        let queryLength = query.lowercased.count

        // Handle empty cases
        if queryLength == 0 {
            return ScoredMatch(score: 1.0, kind: .exact)
        }
        if candidateLength == 0 {
            return nil
        }

        // Ensure buffer capacity
        candidateStorage.ensureCapacity(candidateLength)
        smithWatermanState.ensureCapacity(queryLength)

        // Bitmask prefilter with O(1) ASCII detection (tolerance 0)
        let (candidateMask, candidateIsASCII) = computeCharBitmaskWithASCIICheck(candidateUTF8)
        if !passesCharBitmask(
            queryMask: query.charBitmask,
            candidateMask: candidateMask,
            maxEditDistance: 0
        ) {
            return nil
        }

        let sw = swConfig
        let bonusBoundaryVal = Int32(sw.bonusBoundary)
        let bonusBoundaryWhitespaceVal = Int32(sw.bonusBoundaryWhitespace)
        let bonusBoundaryDelimiterVal = Int32(sw.bonusBoundaryDelimiter)
        let bonusCamelCaseVal = Int32(sw.bonusCamelCase)

        // Merged pass: lowercase + tiered bonus precomputation.
        // NOTE: Lowercasing logic here is intentionally duplicated from lowercaseUTF8()
        // because it interleaves per-position bonus computation in a single O(n) pass.
        // Changes to multi-byte case folding must be applied in both locations.
        // Computes everything the DP needs in a single O(n) scan.
        // Bonus tiers (matching nucleo's char class model):
        //   Position 0 / after whitespace: bonusBoundaryWhitespace (10)
        //   After delimiter (/ : ; |):     bonusBoundaryDelimiter  (9)
        //   After non-word (_, -, . etc):  bonusBoundary           (8)
        //   camelCase / non-digit→digit:   bonusCamelCase          (5)
        //   Current is whitespace:         bonusBoundaryWhitespace (10)
        //   Current is non-word:           bonusBoundary           (8)
        //   Otherwise:                     0
        // Use withMutableBuffers to bypass Array.subscript.modify coroutine overhead.
        // Each array subscript write normally goes through a yield-once coroutine with
        // bounds checking; UnsafeMutablePointer eliminates this for the O(n) merged pass.
        let actualCandidateLength = candidateStorage.withMutableBuffers { bytesPtr, bonusPtr in
        if candidateIsASCII {
            // Fast path: ASCII-only
            var prevByte: UInt8 = 0
            for i in 0..<candidateLength {
                let byte = candidateUTF8[i]
                bytesPtr[i] = confusableASCIIToCanonical(lowercaseASCII(byte))

                let posBonus: Int32
                if i == 0 {
                    posBonus = bonusBoundaryWhitespaceVal
                } else {
                    let currIsUpper = byte >= 0x41 && byte <= 0x5A
                    let currIsLower = byte >= 0x61 && byte <= 0x7A
                    let currIsDigit = byte >= 0x30 && byte <= 0x39
                    let currIsWhitespace = byte == 0x20 || byte == 0x09

                    if currIsWhitespace {
                        posBonus = bonusBoundaryWhitespaceVal
                    } else if !(currIsUpper || currIsLower || currIsDigit) {
                        posBonus = bonusBoundaryVal  // non-word char itself
                    } else {
                        let prevIsWhitespace = prevByte == 0x20 || prevByte == 0x09
                        if prevIsWhitespace {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if prevByte == 0x2F || prevByte == 0x3A
                            || prevByte == 0x3B || prevByte == 0x7C {
                            posBonus = bonusBoundaryDelimiterVal  // after delimiter
                        } else {
                            let prevIsLower = prevByte >= 0x61 && prevByte <= 0x7A
                            if prevIsLower && currIsUpper {
                                posBonus = bonusCamelCaseVal  // camelCase
                            } else {
                                let prevIsDigit = prevByte >= 0x30 && prevByte <= 0x39
                                if !prevIsDigit && currIsDigit {
                                    posBonus = bonusCamelCaseVal  // non-digit → digit
                                } else {
                                    let prevIsUpper = prevByte >= 0x41 && prevByte <= 0x5A
                                    let prevIsAlnum = prevIsLower || prevIsUpper || prevIsDigit
                                    posBonus = (!prevIsAlnum && !prevIsWhitespace) ? bonusBoundaryVal : 0
                                }
                            }
                        }
                    }
                }
                bonusPtr[i] = posBonus
                prevByte = byte
            }
            return candidateLength
        } else {
            // Slow path: multi-byte — lowercase + tiered bonus precomputation
            var prevByte: UInt8 = 0
            var idx = 0
            var outIdx = 0
            while idx < candidateLength {
                let byte = candidateUTF8[idx]
                // Skip combining diacritical marks (U+0300–U+036F)
                if idx + 1 < candidateLength && isCombiningMark(lead: byte, second: candidateUTF8[idx + 1]) {
                    idx += 2
                } else if byte == 0xC3 && idx + 1 < candidateLength {
                    let lowered = lowercaseLatinExtended(candidateUTF8[idx + 1])
                    let ascii = latin1ToASCII(lowered)
                    if ascii != 0 {
                        // Latin-1 diacritic normalizes to ASCII — emit single byte
                        bytesPtr[outIdx] = ascii
                        bonusPtr[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        prevByte = candidateUTF8[idx + 1]
                        outIdx += 1
                    } else {
                        bytesPtr[outIdx] = byte
                        bytesPtr[outIdx + 1] = lowered
                        bonusPtr[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        bonusPtr[outIdx + 1] = 0
                        prevByte = candidateUTF8[idx + 1]
                        outIdx += 2
                    }
                    idx += 2
                } else if (byte == 0xCE || byte == 0xCF) && idx + 1 < candidateLength {
                    let (newLead, newSecond) = lowercaseGreek(lead: byte, second: candidateUTF8[idx + 1])
                    bytesPtr[outIdx] = newLead
                    bytesPtr[outIdx + 1] = newSecond
                    bonusPtr[outIdx] = multiBytePositionBonus(
                        outIdx: outIdx, prevByte: prevByte,
                        bonusBoundaryVal: bonusBoundaryVal,
                        bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                        bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                    )
                    bonusPtr[outIdx + 1] = 0
                    prevByte = candidateUTF8[idx + 1]
                    outIdx += 2
                    idx += 2
                } else if (byte == 0xD0 || byte == 0xD1) && idx + 1 < candidateLength {
                    let (newLead, newSecond) = lowercaseCyrillic(lead: byte, second: candidateUTF8[idx + 1])
                    bytesPtr[outIdx] = newLead
                    bytesPtr[outIdx + 1] = newSecond
                    bonusPtr[outIdx] = multiBytePositionBonus(
                        outIdx: outIdx, prevByte: prevByte,
                        bonusBoundaryVal: bonusBoundaryVal,
                        bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                        bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                    )
                    bonusPtr[outIdx + 1] = 0
                    prevByte = candidateUTF8[idx + 1]
                    outIdx += 2
                    idx += 2
                } else if (byte == 0xC2 || byte == 0xCA) && idx + 1 < candidateLength {
                    let ascii = confusable2ByteToASCII(lead: byte, second: candidateUTF8[idx + 1])
                    if ascii != 0 {
                        // Confusable normalizes to ASCII — emit single byte
                        bytesPtr[outIdx] = ascii
                        let posBonus: Int32
                        if outIdx == 0 {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if ascii == 0x20 {
                            // NBSP normalizes to space — whitespace boundary
                            posBonus = bonusBoundaryWhitespaceVal
                        } else {
                            // Apostrophe/quote/dash — non-word punctuation boundary
                            posBonus = bonusBoundaryVal
                        }
                        bonusPtr[outIdx] = posBonus
                        prevByte = ascii
                        outIdx += 1
                    } else {
                        bytesPtr[outIdx] = byte
                        bytesPtr[outIdx + 1] = candidateUTF8[idx + 1]
                        bonusPtr[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        bonusPtr[outIdx + 1] = 0
                        prevByte = candidateUTF8[idx + 1]
                        outIdx += 2
                    }
                    idx += 2
                } else if byte == 0xE2 && idx + 2 < candidateLength {
                    let ascii = confusable3ByteToASCII(second: candidateUTF8[idx + 1], third: candidateUTF8[idx + 2])
                    if ascii != 0 {
                        // Confusable normalizes to ASCII — emit single byte
                        bytesPtr[outIdx] = ascii
                        let posBonus: Int32
                        if outIdx == 0 {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else {
                            // All 3-byte confusables are punctuation — non-word boundary
                            posBonus = bonusBoundaryVal
                        }
                        bonusPtr[outIdx] = posBonus
                        prevByte = ascii
                        outIdx += 1
                    } else {
                        bytesPtr[outIdx] = byte
                        bytesPtr[outIdx + 1] = candidateUTF8[idx + 1]
                        bytesPtr[outIdx + 2] = candidateUTF8[idx + 2]
                        bonusPtr[outIdx] = multiBytePositionBonus(
                            outIdx: outIdx, prevByte: prevByte,
                            bonusBoundaryVal: bonusBoundaryVal,
                            bonusBoundaryWhitespaceVal: bonusBoundaryWhitespaceVal,
                            bonusBoundaryDelimiterVal: bonusBoundaryDelimiterVal
                        )
                        bonusPtr[outIdx + 1] = 0
                        bonusPtr[outIdx + 2] = 0
                        prevByte = candidateUTF8[idx + 2]
                        outIdx += 3
                    }
                    idx += 3
                } else {
                    bytesPtr[outIdx] = confusableASCIIToCanonical(lowercaseASCII(byte))
                    let posBonus: Int32
                    if outIdx == 0 {
                        posBonus = bonusBoundaryWhitespaceVal
                    } else {
                        let currIsUpper = byte >= 0x41 && byte <= 0x5A
                        let currIsLower = byte >= 0x61 && byte <= 0x7A
                        let currIsDigit = byte >= 0x30 && byte <= 0x39
                        let currIsWhitespace = byte == 0x20 || byte == 0x09

                        if currIsWhitespace {
                            posBonus = bonusBoundaryWhitespaceVal
                        } else if !(currIsUpper || currIsLower || currIsDigit) {
                            posBonus = bonusBoundaryVal
                        } else {
                            let prevIsWhitespace = prevByte == 0x20 || prevByte == 0x09
                            if prevIsWhitespace {
                                posBonus = bonusBoundaryWhitespaceVal
                            } else if prevByte == 0x2F || prevByte == 0x3A
                                || prevByte == 0x3B || prevByte == 0x7C {
                                posBonus = bonusBoundaryDelimiterVal
                            } else {
                                let prevIsLower = prevByte >= 0x61 && prevByte <= 0x7A
                                if prevIsLower && currIsUpper {
                                    posBonus = bonusCamelCaseVal
                                } else {
                                    let prevIsDigit = prevByte >= 0x30 && prevByte <= 0x39
                                    if !prevIsDigit && currIsDigit {
                                        posBonus = bonusCamelCaseVal
                                    } else {
                                        let prevIsAlnum = (prevByte >= 0x41 && prevByte <= 0x5A)
                                            || (prevByte >= 0x61 && prevByte <= 0x7A)
                                            || prevByte == 0xC3
                                            || prevByte == 0xCE || prevByte == 0xCF
                                            || prevByte == 0xD0 || prevByte == 0xD1
                                            || (prevByte >= 0x80 && prevByte <= 0xBF)
                                            || prevIsDigit
                                        posBonus = (prevIsAlnum || prevIsWhitespace) ? 0 : bonusBoundaryVal
                                    }
                                }
                            }
                        }
                    }
                    bonusPtr[outIdx] = posBonus
                    prevByte = byte
                    outIdx += 1
                    idx += 1
                }
            }
            return outIdx
        }
        }

        // Exact match early exit (before atom split so multi-word self-matches return .exact)
        if actualCandidateLength == queryLength {
            var isExact = true
            for i in 0..<queryLength {
                if candidateStorage.bytes[i] != query.lowercased[i] {
                    isExact = false
                    break
                }
            }
            if isExact {
                return ScoredMatch(score: 1.0, kind: .exact)
            }
        }

        return candidateStorage.withReadBuffers(length: actualCandidateLength) { candidateSpan, bonusSpan in
            return query.lowercased.withUnsafeBufferPointer { querySpan -> ScoredMatch? in
                if query.atoms.count > 1 {
                    // Multi-atom path: score each word independently, AND semantics
                    var totalRawScore: Int32 = 0
                    for atom in query.atoms {
                        let atomQuery = UnsafeBufferPointer(
                            rebasing: querySpan[atom.start..<(atom.start + atom.length)]
                        )
                        let atomScore = smithWatermanScore(
                            query: atomQuery,
                            candidate: candidateSpan,
                            bonus: bonusSpan,
                            state: &smithWatermanState,
                            config: sw
                        )
                        if atomScore <= 0 {
                            return nil
                        }
                        totalRawScore += atomScore
                    }

                    let maxScore = query.maxSmithWatermanScore
                    guard maxScore > 0 else { return nil }
                    let normalizedScore = min(1.0, max(0.0, Double(totalRawScore) / Double(maxScore)))
                    if normalizedScore >= query.config.minScore {
                        return ScoredMatch(score: normalizedScore, kind: .alignment)
                    }
                    return nil
                }

                // Single-word path
                // Run Smith-Waterman DP with precomputed bonus array
                let rawScore = smithWatermanScore(
                    query: querySpan,
                    candidate: candidateSpan,
                    bonus: bonusSpan,
                    state: &smithWatermanState,
                    config: sw
                )

                // Compute best SW score
                var bestScore: Double = -1
                var bestKind: MatchKind = .alignment

                if rawScore > 0 {
                    let maxScore = query.maxSmithWatermanScore
                    if maxScore > 0 {
                        let normalizedScore = min(1.0, max(0.0, Double(rawScore) / Double(maxScore)))
                        if normalizedScore >= query.config.minScore {
                            bestScore = normalizedScore
                        }
                    }
                }

                // Acronym fallback: compete with SW score for short queries (2-8 chars)
                if queryLength >= 2 && queryLength <= 8 {
                    let boundaryMask = computeBoundaryMaskCompressed(originalBytes: candidateUTF8, isASCII: candidateIsASCII)
                    var wordCount = boundaryMask.nonzeroBitCount
                    if actualCandidateLength > 64 {
                        for i in 64..<actualCandidateLength {
                            if isWordBoundary(at: i, in: candidateSpan) {
                                wordCount += 1
                            }
                        }
                    }
                    if wordCount >= 3 && wordCount >= queryLength {
                        var acronymState = ScoringState()
                        acronymState.boundaryMask = boundaryMask
                        acronymState.bestScore = bestScore

                        scoreAcronym(
                            querySpan: querySpan,
                            candidateSpan: candidateSpan,
                            candidateUTF8: candidateUTF8,
                            query: query,
                            candidateLength: actualCandidateLength,
                            acronymWeight: 1.0,
                            state: &acronymState,
                            wordInitials: &wordInitials
                        )

                        if acronymState.bestScore > bestScore {
                            bestScore = acronymState.bestScore
                            bestKind = acronymState.bestKind
                        }
                    }
                }

                if bestScore >= query.config.minScore {
                    return ScoredMatch(score: min(bestScore, 1.0), kind: bestKind)
                }

                return nil
            }
        }
    }
}
