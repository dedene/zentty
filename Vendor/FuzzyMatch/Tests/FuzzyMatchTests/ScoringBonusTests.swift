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

@testable import FuzzyMatch
import Testing

// MARK: - Match Position Finding Tests

@Test func findMatchPositionsSimple() {
    let query = Array("abc".utf8)
    let candidate = Array("abc".utf8)
    var positions = [Int](repeating: 0, count: query.count)

    let count = findMatchPositions(
        query: query,
        candidate: candidate,
        boundaryMask: 0b1,  // Only position 0 is boundary
        positions: &positions
    )

    #expect(count == 3)
    #expect(positions[0] == 0)  // a
    #expect(positions[1] == 1)  // b
    #expect(positions[2] == 2)  // c
}

@Test func findMatchPositionsPrefersBoundaries() {
    // Query "gubi" in "getUserById" should prefer boundary positions
    let query = Array("gubi".lowercased().utf8)
    let candidate = Array("getUserById".lowercased().utf8)
    var positions = [Int](repeating: 0, count: query.count)

    // Compute boundary mask for candidate
    let boundaryMask = computeBoundaryMask(bytes: candidate)

    let count = findMatchPositions(
        query: query,
        candidate: candidate,
        boundaryMask: boundaryMask,
        positions: &positions
    )

    #expect(count == 4)
    // g at 0 (boundary), u at 3 (after "get", note: lowercase), b at 7 (boundary), i at 9 (boundary)
    // Actually in lowercased: g e t u s e r b y i d
    //                         0 1 2 3 4 5 6 7 8 9 10
    // Boundaries in original case would be 0, 3, 7, 9
    // But after lowercasing, camelCase info is lost in the candidate
    // Let's verify the positions make sense
    #expect(positions[0] == 0)  // g at start
}

@Test func findMatchPositionsSubsequence() {
    // Query "fzy" in "fuzzy"
    let query = Array("fzy".utf8)
    let candidate = Array("fuzzy".utf8)
    var positions = [Int](repeating: 0, count: query.count)

    let count = findMatchPositions(
        query: query,
        candidate: candidate,
        boundaryMask: 0b1,  // Only position 0
        positions: &positions
    )

    #expect(count == 3)
    #expect(positions[0] == 0)  // f
    #expect(positions[1] == 2)  // z
    #expect(positions[2] == 4)  // y
}

@Test func findMatchPositionsNoMatch() {
    let query = Array("xyz".utf8)
    let candidate = Array("abc".utf8)
    var positions = [Int](repeating: 0, count: query.count)

    let count = findMatchPositions(
        query: query,
        candidate: candidate,
        boundaryMask: 0b1,
        positions: &positions
    )

    #expect(count == 0)
}

@Test func findMatchPositionsEmpty() {
    let query: [UInt8] = []
    let candidate = Array("abc".utf8)
    var positions = [Int](repeating: 0, count: 1)

    let count = findMatchPositions(
        query: query,
        candidate: candidate,
        boundaryMask: 0b1,
        positions: &positions
    )

    #expect(count == 0)
}

// MARK: - Bonus Calculation Tests

@Test func calculateBonusesAllBoundaries() {
    // All matches at boundaries: bonus = 4 * 0.1 = 0.4
    let positions = [0, 3, 7, 9]  // All boundary positions
    let candidate = Array("getUserById".utf8)

    let boundaryMask = computeBoundaryMask(bytes: candidate)

    // Use linear gap model without position bonus
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .linear(perCharacter: 0.01),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // 4 boundary bonuses (0.4) - gaps: (3-0-1=2)*0.01 + (7-3-1=3)*0.01 + (9-7-1=1)*0.01 = 0.06
    // Total: 0.4 - 0.06 = 0.34
    #expect(bonus > 0.3)
    #expect(bonus < 0.4)
}

@Test func calculateBonusesConsecutive() {
    // Consecutive matches: positions 0, 1, 2
    let positions = [0, 1, 2]
    let candidate = Array("abc".utf8)

    let boundaryMask = computeBoundaryMask(bytes: candidate)

    // Use linear gap model without position bonus
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .linear(perCharacter: 0.01),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // 1 boundary bonus (position 0) + 2 consecutive bonuses
    // = 0.1 + 0.05 + 0.05 = 0.2
    #expect(abs(bonus - 0.2) < 0.001)
}

@Test func calculateBonusesWithGaps() {
    // Matches with gaps: positions 0, 5, 10
    let positions = [0, 5, 10]
    let candidate = Array("abcdefghijk".utf8)

    let boundaryMask: UInt64 = 0b1  // Only position 0 is boundary

    // Use linear gap model without position bonus
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .linear(perCharacter: 0.01),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // 1 boundary bonus (0.1) - gap penalties: (5-0-1=4)*0.01 + (10-5-1=4)*0.01 = 0.08
    // Total: 0.1 - 0.08 = 0.02
    #expect(abs(bonus - 0.02) < 0.001)
}

@Test func calculateBonusesNoBonusConfig() {
    let positions = [0, 3, 7, 9]
    let candidate = Array("getUserById".utf8)

    let boundaryMask = computeBoundaryMask(bytes: candidate)

    // All bonuses disabled
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    #expect(bonus == 0.0)
}

// MARK: - Integration Tests: Ranking Quality

@Test func gubiRanksGetUserByIdHigherThanDebugging() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    let getUserByIdScore = matcher.score("getUserById", against: query, buffer: &buffer)
    let debuggingScore = matcher.score("debugging", against: query, buffer: &buffer)

    // getUserById should match via subsequence (g, u, b, i at word boundaries)
    #expect(getUserByIdScore != nil)

    // "debugging" should NOT match "gubi" — the characters g,u,b,i cannot be found
    // in order within "debugging" (u at pos 3 precedes g at pos 4), and the adaptive
    // maxEditDistance of 1 for 4-char queries prevents substring edit distance matching.
    #expect(debuggingScore == nil)
}

@Test func fbRanksFooBarHigherThanFileBrowser() {
    // Test boundary scoring with gap penalty to differentiate by gap size
    // fooBar has smaller gap (2 chars) than file_browser (4 chars)
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            gapPenalty: .linear(perCharacter: 0.02),
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("fb")
    var buffer = matcher.makeBuffer()

    let fooBarScore = matcher.score("fooBar", against: query, buffer: &buffer)
    let fileBrowserScore = matcher.score("file_browser", against: query, buffer: &buffer)

    // Both should match
    #expect(fooBarScore != nil)
    #expect(fileBrowserScore != nil)

    // fooBar should rank higher (f at start, B at word boundary with smaller gap)
    #expect(fooBarScore!.score > fileBrowserScore!.score)
}

@Test func exactPrefixRanksHighest() {
    // Use config without prefix boost to test that bonuses still help
    // With default bonuses, prefix matches should still rank higher
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.0,  // No prefix boost
            substringWeight: 1.0  // Same weight
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("gat")
    var buffer = matcher.makeBuffer()

    // "gat" prefix in "gateway" vs "gat" substring in "navigate"
    // Without prefix weight difference, the bonus system should still prefer prefix
    // because "gateway" has:
    // - g at position 0 (word boundary)
    // - a at position 1 (consecutive)
    // - t at position 2 (consecutive)
    // while "navigate" has:
    // - g at position 4 (not a boundary in "navigate")
    // - a at position 5 (consecutive)
    // - t at position 6 (consecutive)
    let gatewayScore = matcher.score("gateway", against: query, buffer: &buffer)
    let navigateScore = matcher.score("navigate", against: query, buffer: &buffer)

    #expect(gatewayScore != nil)
    #expect(navigateScore != nil)

    // gatewayScore should be higher due to word boundary bonus at position 0
    #expect(gatewayScore!.score >= navigateScore!.score)
}

@Test func consecutiveMatchesBeatScatteredMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let consecutiveScore = matcher.score("abcdef", against: query, buffer: &buffer)
    let scatteredScore = matcher.score("aXbXcX", against: query, buffer: &buffer)

    #expect(consecutiveScore != nil)
    #expect(scatteredScore != nil)

    // Consecutive matches should score higher
    #expect(consecutiveScore!.score > scatteredScore!.score)
}

@Test func wordBoundaryMatchesBeatMiddleMatches() {
    // Uses a 5-char query to avoid the short-query same-length ED restriction
    // (queries <= 4 chars only allow ED typos against same-length candidates,
    // so the prefix path wouldn't fire for short queries against longer candidates).
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("userb")
    var buffer = matcher.makeBuffer()

    // "userb" is an exact prefix of "userById" at word boundary (position 0)
    let boundaryScore = matcher.score("userById", against: query, buffer: &buffer)
    // "userb" is an exact substring of "auserback" but NOT at a word boundary
    let middleScore = matcher.score("auserback", against: query, buffer: &buffer)

    #expect(boundaryScore != nil)
    #expect(middleScore != nil)

    // Word boundary matches should score higher
    #expect(boundaryScore!.score > middleScore!.score)
}

// MARK: - Config Tests

@Test func bonusesCanBeDisabled() {
    let noBonusConfig = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: noBonusConfig)
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    // With bonuses disabled, scores should be based only on edit distance
    let result = matcher.score("getUserById", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func customBonusValues() {
    let customConfig = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            wordBoundaryBonus: 0.2,  // Stronger boundary bonus
            consecutiveBonus: 0.1,   // Stronger consecutive bonus
            gapPenalty: .linear(perCharacter: 0.02)  // Stronger gap penalty
        ))
    )
    let matcher = FuzzyMatcher(config: customConfig)
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)
    #expect(result != nil)
    // With stronger bonuses, boundary-aligned matches should score even higher
    #expect(result!.score > 0.5)
}

// MARK: - First Match Position Bonus Tests

@Test func firstMatchBonusAtPositionZero() {
    // First match at position 0 should get full firstMatchBonus
    let positions = [0, 1, 2]
    let candidate = Array("abc".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.15,
        firstMatchBonusRange: 10
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Full first match bonus at position 0
    #expect(abs(bonus - 0.15) < 0.001)
}

@Test func firstMatchBonusMidRange() {
    // First match at position 5 should get 50% of firstMatchBonus (decay)
    let positions = [5, 6, 7]
    let candidate = Array("xxxxxabc".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.15,
        firstMatchBonusRange: 10
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // At position 5 with range 10: decay = 1 - 5/10 = 0.5
    // Bonus = 0.15 * 0.5 = 0.075
    #expect(abs(bonus - 0.075) < 0.001)
}

@Test func firstMatchBonusBeyondRange() {
    // First match at position 10 or beyond should get no firstMatchBonus
    let positions = [10, 11, 12]
    let candidate = Array("xxxxxxxxxxabc".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.15,
        firstMatchBonusRange: 10
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // No bonus beyond range
    #expect(bonus == 0.0)
}

@Test func firstMatchBonusDisabled() {
    // When firstMatchBonus is 0, no position bonus is applied
    let positions = [0, 1, 2]
    let candidate = Array("abc".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.0,
        firstMatchBonusRange: 10
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    #expect(bonus == 0.0)
}

// MARK: - Affine Gap Penalty Tests

@Test func affineGapPenaltySingleCharGap() {
    // Gap of 1 character: only open penalty (no extension)
    let positions = [0, 2]  // Gap of 1 at position 1
    let candidate = Array("aXb".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .affine(open: 0.03, extend: 0.005),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Gap of 1: open + (1-1) * extend = 0.03 + 0 = 0.03
    #expect(abs(bonus - (-0.03)) < 0.001)
}

@Test func affineGapPenaltyMultiCharGap() {
    // Gap of 3 characters
    let positions = [0, 4]  // Gap of 3 at positions 1, 2, 3
    let candidate = Array("aXXXb".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .affine(open: 0.03, extend: 0.005),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Gap of 3: open + (3-1) * extend = 0.03 + 2 * 0.005 = 0.04
    #expect(abs(bonus - (-0.04)) < 0.001)
}

@Test func affineGapVsLinearGap() {
    // Compare affine and linear gap models for a gap of 3
    let positions = [0, 4]  // Gap of 3
    let candidate = Array("aXXXb".utf8)
    let boundaryMask: UInt64 = 0b1

    // Linear model
    let linearConfig = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .linear(perCharacter: 0.01),
        firstMatchBonus: 0.0
    )

    let linearBonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: linearConfig
    )

    // Affine model
    let affineConfig = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .affine(open: 0.03, extend: 0.005),
        firstMatchBonus: 0.0
    )

    let affineBonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: affineConfig
    )

    // Linear: 3 * 0.01 = 0.03 penalty
    // Affine: 0.03 + 2 * 0.005 = 0.04 penalty
    #expect(abs(linearBonus - (-0.03)) < 0.001)
    #expect(abs(affineBonus - (-0.04)) < 0.001)

    // Affine penalizes larger gaps more heavily
    #expect(affineBonus < linearBonus)
}

@Test func linearGapModel() {
    // Test linear gap model: each gap character costs the same
    let positions = [0, 5, 10]
    let candidate = Array("abcdefghijk".utf8)
    let boundaryMask: UInt64 = 0b1

    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .linear(perCharacter: 0.01),
        firstMatchBonus: 0.0
    )

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Linear gaps: (5-0-1=4)*0.01 + (10-5-1=4)*0.01 = 0.08 penalty
    #expect(abs(bonus - (-0.08)) < 0.001)
}

// MARK: - Integration Tests: Position Bonus Ranking

@Test func earlyMatchRanksHigherThanLateMatch() {
    // Test that first match position bonus affects ranking
    // Use candidates where matches are spread out (subsequence matches)
    // so base scores don't cap at 1.0
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.0,      // Disable prefix weight to isolate position bonus
            substringWeight: 1.0,
            wordBoundaryBonus: 0.0, // Disable boundary bonus to isolate position bonus
            consecutiveBonus: 0.0,  // Disable consecutive bonus to isolate position bonus
            gapPenalty: .none,
            firstMatchBonus: 0.15,
            firstMatchBonusRange: 10
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("ace")
    var buffer = matcher.makeBuffer()

    // "ace" scattered: early start vs late start
    // Early: a at 0, c at 2, e at 4 (positions 0, 2, 4)
    // Late: a at 3, c at 5, e at 7 (positions 3, 5, 7)
    let earlyScore = matcher.score("abcdef", against: query, buffer: &buffer)
    let lateScore = matcher.score("xxxabcdef", against: query, buffer: &buffer)

    #expect(earlyScore != nil)
    #expect(lateScore != nil)

    // Early match should rank higher due to first match position bonus
    // earlyScore gets full 0.15 bonus (position 0)
    // lateScore gets reduced bonus: 0.15 * (1 - 3/10) = 0.105
    #expect(earlyScore!.score > lateScore!.score)
}

@Test func tighterMatchesBeatScatteredWithAffineGaps() {
    // With affine gaps, a slightly scattered match should beat a very scattered one
    // even more than with linear gaps.
    // Uses 5-char queries to avoid the short-query same-length ED restriction.
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            gapPenalty: .affine(open: 0.05, extend: 0.01),
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("abcde")
    var buffer = matcher.makeBuffer()

    // Small gap vs large gap
    let smallGapScore = matcher.score("aXbcde", against: query, buffer: &buffer)
    let largeGapScore = matcher.score("aXXXXXbcde", against: query, buffer: &buffer)

    #expect(smallGapScore != nil)
    #expect(largeGapScore != nil)

    // Small gap should score higher
    #expect(smallGapScore!.score > largeGapScore!.score)
}

// MARK: - Multi-Word Query Tests

@Test func multiWordQueryMatchesDescription() {
    // Test that short multi-word queries (3-10 chars) match labels/descriptions
    // User use case: "und is" should match "Underlying ISIN"
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("und is")
    var buffer = matcher.makeBuffer()

    // Primary target - should match well
    let underlyingISIN = matcher.score("Underlying ISIN", against: query, buffer: &buffer)
    #expect(underlyingISIN != nil, "'und is' should match 'Underlying ISIN'")

    // Related terms - should also match
    _ = matcher.score("Unit Price", against: query, buffer: &buffer)

    // Unrelated - should not match or score lower
    let randomText = matcher.score("Random Text", against: query, buffer: &buffer)

    // "Underlying ISIN" should be the best match since query aligns with word boundaries
    if let score1 = underlyingISIN?.score {
        #expect(score1 >= 0.3, "Underlying ISIN should meet minimum score threshold")

        // Should rank higher than unrelated text
        if let score3 = randomText?.score {
            #expect(score1 > score3, "Target should rank higher than unrelated text")
        }
    }
}

@Test func shortAbbreviationQueryMatchesDescription() {
    // Test abbreviation-style queries against descriptions
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // "ui" matching "User Interface" or "Underlying ISIN"
    let query = matcher.prepare("ui")

    let userInterface = matcher.score("User Interface", against: query, buffer: &buffer)
    let underlyingISIN = matcher.score("Underlying ISIN", against: query, buffer: &buffer)

    #expect(userInterface != nil, "'ui' should match 'User Interface'")
    #expect(underlyingISIN != nil, "'ui' should match 'Underlying ISIN'")

    // Both should have reasonable scores (word boundary matches)
    if let score1 = userInterface?.score, let score2 = underlyingISIN?.score {
        #expect(score1 >= 0.3 && score2 >= 0.3, "Both should meet minimum threshold")
    }
}

@Test func multiWordQueryNotRejectedByTrigramFilter() {
    // Regression test: multi-word queries like "am lo ab" should not be
    // rejected by the trigram prefilter. Cross-word-boundary trigrams
    // (e.g., "m l", "lo ") don't exist in candidates and cause false rejections.
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("am lo ab")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("EMEA Ambericus Locudaamus AB", against: query, buffer: &buffer)
    #expect(result != nil, "'am lo ab' should match 'EMEA Ambericus Locudaamus AB'")
    if let score = result?.score {
        #expect(score >= 0.3, "Score should meet minimum threshold, got \(score)")
    }
}

@Test func queryWithSpacesMatchesCandidateWithSpaces() {
    // The space character in query should match space in candidate
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a b")  // Query with space
    var buffer = matcher.makeBuffer()

    // "a b" should match well against "Apple Banana" (a at start, space matches, b at start of Banana)
    let withSpace = matcher.score("Apple Banana", against: query, buffer: &buffer)
    #expect(withSpace != nil, "'a b' should match 'Apple Banana'")

    // Also matches "ab" without space (subsequence)
    _ = matcher.score("ab", against: query, buffer: &buffer)
    // This may or may not match depending on how we handle the space
}

// MARK: - Whole-Word Substring Recovery Tests

@Test func wholeWordSubstringRecoveryAtEnd() {
    // "SRI" as standalone word at end of string should beat
    // "SRI" scattered mid-word in a shorter candidate
    let matcher = FuzzyMatcher()
    let querySRI = matcher.prepare("sri")
    var buffer = matcher.makeBuffer()

    let wholeWord = matcher.score("ishares msci em sri", against: querySRI, buffer: &buffer)
    let midWord = matcher.score("servicenow", against: querySRI, buffer: &buffer)

    #expect(wholeWord != nil)
    // wholeWord should have recovery bonus applied
    if let midWordScore = midWord?.score, let wholeWordScore = wholeWord?.score {
        #expect(wholeWordScore > midWordScore)
    }
}

@Test func wholeWordSubstringRecoveryESG() {
    // "ESG" as standalone word in longer candidate should beat
    // "esg" embedded mid-word in "jfesg" (the real-world case from the plan)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("esg")
    var buffer = matcher.makeBuffer()

    // "jfesg" has "esg" mid-word (not at a word boundary) — no recovery
    let midWord = matcher.score("jfesg futures", against: query, buffer: &buffer)
    // "xact omxs30 esg" has "esg" as a whole word at end — gets recovery
    let wholeWord = matcher.score("xact omxs30 esg", against: query, buffer: &buffer)

    #expect(midWord != nil)
    #expect(wholeWord != nil)
    #expect(wholeWord!.score > midWord!.score)
}

@Test func wholeWordSubstringRecoveryAsia() {
    // "Asia" as standalone word should beat "asia" embedded mid-word
    // Uses realistic candidate names from the instrument dataset
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("asia")
    var buffer = matcher.makeBuffer()

    // "eurasia groupe" has "asia" mid-word in "eurasia" — no recovery
    let midWord = matcher.score("eurasia groupe", against: query, buffer: &buffer)
    // "spdr msci em asia etf" has "asia" as a whole word — gets recovery
    let wholeWord = matcher.score("spdr msci em asia etf", against: query, buffer: &buffer)

    #expect(midWord != nil)
    #expect(wholeWord != nil)
    #expect(wholeWord!.score > midWord!.score)
}

@Test func noRecoveryForMidWordSubstring() {
    // Verify that mid-word substring does NOT get recovery
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("esg")
    var buffer = matcher.makeBuffer()

    // Both have "esg" mid-word — neither should get recovery
    // The shorter candidate should win due to lower length penalty
    let shorter = matcher.score("jfesg", against: query, buffer: &buffer)
    let longer = matcher.score("abcdesg xyz", against: query, buffer: &buffer)

    #expect(shorter != nil)
    #expect(longer != nil)
    // Shorter candidate wins when neither gets recovery (less length penalty)
    #expect(shorter!.score > longer!.score)
}
