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

// MARK: - Exact Score Verification Tests
//
// These tests verify that scoring produces specific expected values, not just
// relative ordering. This catches subtle scoring regressions that comparative
// tests would miss.

// MARK: - Normalized Score Calculation Verification

@Test func normalizedScoreExactMatchIsOne() {
    let score = normalizedScore(
        editDistance: 0,
        queryLength: 10,
        kind: .exact,
        config: EditDistanceConfig(prefixWeight: 1.0, substringWeight: 1.0)
    )
    #expect(score == 1.0)
}

@Test func normalizedScoreEditDistanceOne() {
    // editDistance: 1, queryLength: 5
    // base = 1.0 - (1/5) = 0.8
    let score = normalizedScore(
        editDistance: 1,
        queryLength: 5,
        kind: .exact,
        config: EditDistanceConfig(prefixWeight: 1.0, substringWeight: 1.0)
    )
    #expect(abs(score - 0.8) < 0.0001)
}

@Test func normalizedScoreEditDistanceTwo() {
    // editDistance: 2, queryLength: 5
    // base = 1.0 - (2/5) = 0.6
    let score = normalizedScore(
        editDistance: 2,
        queryLength: 5,
        kind: .exact,
        config: EditDistanceConfig(prefixWeight: 1.0, substringWeight: 1.0)
    )
    #expect(abs(score - 0.6) < 0.0001)
}

@Test func normalizedScorePrefixWeightApplied() {
    // editDistance: 1, queryLength: 5, prefixWeight: 1.5
    // base = 0.8, weighted = max(0, 1.0 - 0.2/1.5) ≈ 0.8667
    let score = normalizedScore(
        editDistance: 1,
        queryLength: 5,
        kind: .prefix,
        config: EditDistanceConfig(prefixWeight: 1.5, substringWeight: 1.0)
    )
    let expected = 1.0 - 0.2 / 1.5  // ≈ 0.8667
    #expect(abs(score - expected) < 0.0001)
}

@Test func normalizedScoreSubstringWeightApplied() {
    // editDistance: 0, queryLength: 5, substringWeight: 0.8
    // With asymptotic formula: max(0, 1.0 - 0/0.8) = 1.0
    // Perfect matches always score 1.0 regardless of weight
    let score = normalizedScore(
        editDistance: 0,
        queryLength: 5,
        kind: .substring,
        config: EditDistanceConfig(prefixWeight: 1.0, substringWeight: 0.8)
    )
    #expect(score == 1.0)
}

@Test func calculateBonusesAffineGapExactValue() {
    // Test affine gap model: opening penalty + extension penalty
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .affine(open: 0.03, extend: 0.005),
        firstMatchBonus: 0.0
    )

    let positions = [0, 5]  // Gap of 4 characters
    let candidate = Array("abcdef".utf8)
    let boundaryMask: UInt64 = 0b1  // Only position 0

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Expected:
    // Position 0: boundary bonus = 0.1
    // Position 5: affine gap = gapOpen + (gap-1)*gapExtend = 0.03 + 3*0.005 = 0.045
    // Total: 0.1 - 0.045 = 0.055
    let expected: Double = 0.055
    #expect(abs(bonus - expected) < 0.001, "Expected \(expected), got \(bonus)")
}

@Test func calculateBonusesFirstMatchBonusExactValue() {
    // Test first match bonus with position decay
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.15,
        firstMatchBonusRange: 10
    )

    // Match at position 0 - full bonus
    let positions0 = [0]
    let candidate = Array("abcdefghij".utf8)
    let boundaryMask: UInt64 = 0

    let bonus0 = calculateBonuses(
        matchPositions: positions0,
        positionCount: 1,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Position 0: decay = 1 - 0/10 = 1.0, bonus = 0.15 * 1.0 = 0.15
    #expect(abs(bonus0 - 0.15) < 0.001, "Position 0 should get full bonus 0.15, got \(bonus0)")

    // Match at position 5 - half bonus
    let positions5 = [5]
    let bonus5 = calculateBonuses(
        matchPositions: positions5,
        positionCount: 1,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Position 5: decay = 1 - 5/10 = 0.5, bonus = 0.15 * 0.5 = 0.075
    #expect(abs(bonus5 - 0.075) < 0.001, "Position 5 should get bonus 0.075, got \(bonus5)")
}

// MARK: - Full Matcher Score Verification

@Test func exactMatchScoreIsOne() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("hello")
    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func exactMatchCaseInsensitiveScoreIsOne() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("HeLLo")
    let result = matcher.score("hElLO", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func prefixMatchScoreWithDefaultConfig() {
    // Test prefix match score with known configuration
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.5,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("test")  // 4 chars
    let result = matcher.score("testing", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .prefix)

    // With no bonuses and prefixWeight 1.5:
    // editDistance = 0, base = 1.0, then length penalty (7-4)*0.003 = 0.009
    // with exact prefix offset of min(0.009*0.8, 0.15) = 0.0072
    // final ≈ 0.998
    #expect(result!.score > 0.99)
}

@Test func perfectPrefixScoresHigherThanTransposedPrefix() {
    // A perfect prefix match (distance=0) should score strictly higher than
    // a transposed prefix match (distance=1), even with prefix weight boosting.
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.5,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    // "test" is a perfect prefix of "testing" → distance=0, score=1.0
    let perfectQuery = matcher.prepare("test")
    let perfectResult = matcher.score("testing", against: perfectQuery, buffer: &buffer)

    // "tset" is a transposed prefix of "testing" → distance=1
    let transposedQuery = matcher.prepare("tset")
    let transposedResult = matcher.score("testing", against: transposedQuery, buffer: &buffer)

    #expect(perfectResult != nil)
    #expect(transposedResult != nil)
    #expect(perfectResult!.score > transposedResult!.score,
            "Perfect prefix (\(perfectResult!.score)) should score strictly higher than transposed prefix (\(transposedResult!.score))")
}

@Test func substringMatchScoreWithKnownConfig() {
    let config = MatchConfig(
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.0,
            substringWeight: 0.9,
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("test")
    let result = matcher.score("unittest", against: query, buffer: &buffer)

    #expect(result != nil)

    // editDistance = 0, base = 1.0, substringWeight = 0.9
    // With asymptotic formula: max(0, 1.0 - 0/0.9) = 1.0
    // Perfect matches always score 1.0 regardless of weight
    // With length penalty: (8-4)*0.003 = 0.012 deducted from base 1.0
    if let score = result?.score {
        #expect(score > 0.97, "Expected >0.97, got \(score)")
    }
}

@Test func typoMatchScoreVerification() {
    let config = MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(
            maxEditDistance: 2,
            prefixWeight: 1.0,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    // "helo" vs "hello" - one insertion needed, distance = 1
    let query = matcher.prepare("helo")  // 4 chars
    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)

    // base = 1.0 - 1/4 = 0.75
    if let score = result?.score {
        #expect(abs(score - 0.75) < 0.01, "Expected ~0.75, got \(score)")
    }
}

@Test func transpositionMatchScoreVerification() {
    let config = MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(
            maxEditDistance: 2,
            prefixWeight: 1.0,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.0,
            consecutiveBonus: 0.0,
            gapPenalty: .none,
            firstMatchBonus: 0.0
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    // "teh" vs "the" - one transposition, distance = 1
    let query = matcher.prepare("teh")  // 3 chars
    let result = matcher.score("the", against: query, buffer: &buffer)

    #expect(result != nil)

    // base = 1.0 - 1/3 ≈ 0.667, same-length boost: 0.667 + 0.333*0.7 = 0.9
    if let score = result?.score {
        #expect(abs(score - 0.9) < 0.01, "Expected ~0.9 (with same-length boost), got \(score)")
    }
}

// MARK: - Word Boundary Score Verification

@Test func gubiMatchesGetUserByIdWithBonuses() {
    let config = MatchConfig(
        minScore: 0.1,
        algorithm: .editDistance(EditDistanceConfig(
            maxEditDistance: 2,
            prefixWeight: 1.0,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.1,
            consecutiveBonus: 0.05,
            gapPenalty: .linear(perCharacter: 0.01),
            firstMatchBonus: 0.15,
            firstMatchBonusRange: 10
        ))
    )
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("gubi")
    let getUserByIdResult = matcher.score("getUserById", against: query, buffer: &buffer)

    // "gubi" matches "getUserById" via word-boundary subsequence (g-u-b-i at boundaries)
    #expect(getUserByIdResult != nil)
    #expect(getUserByIdResult!.score > 0.3, "getUserById should score well due to boundary bonuses, got \(getUserByIdResult!.score)")
}

// MARK: - Score Range Verification

@Test func allScoresBetweenZeroAndOne() {
    let matcher = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 3))
    ))
    var buffer = matcher.makeBuffer()

    let testCases: [(String, String)] = [
        ("hello", "hello"),      // Exact
        ("hello", "helloworld"), // Prefix
        ("hello", "worldhello"), // Substring
        ("helo", "hello"),       // Typo
        ("teh", "the"),          // Transposition
        ("abc", "abcdef"),       // Short query
        ("x", "xyz")            // Single char
    ]

    for (queryStr, candidate) in testCases {
        let query = matcher.prepare(queryStr)
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            #expect(result.score >= 0.0, "Score should be >= 0 for \(queryStr) vs \(candidate)")
            #expect(result.score <= 1.0, "Score should be <= 1 for \(queryStr) vs \(candidate)")
        }
    }
}

// MARK: - Score Precision Tests

@Test func scorePrecisionNotLostInCalculation() {
    // Verify floating point calculations don't lose precision
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .linear(perCharacter: 0.01)
    )

    // These specific values should produce predictable results
    let positions = [0, 1, 2, 3, 4]
    let candidate = Array("abcde".utf8)
    let boundaryMask: UInt64 = 0b1  // Only position 0

    let bonus = calculateBonuses(
        matchPositions: positions,
        positionCount: positions.count,
        candidateBytes: candidate,
        boundaryMask: boundaryMask,
        config: config
    )

    // Position 0: boundary = 0.1
    // Positions 1-4: consecutive = 4 * 0.05 = 0.2
    // Total: 0.3
    // Plus firstMatchBonus (default 0.15 at position 0)
    let expectedBase: Double = 0.1 + 0.2
    let expectedFirstMatch: Double = 0.15  // Full bonus at position 0

    let expected = expectedBase + expectedFirstMatch
    #expect(abs(bonus - expected) < 0.0001, "Expected \(expected), got \(bonus)")
}
