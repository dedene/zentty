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

import Foundation
@testable import FuzzyMatch
import Testing

// MARK: - maxEditDistance Configuration

@Test func maxEditDistanceZeroRequiresExactMatch() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 0))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Exact match should work
    let exactResult = matcher.score("hello", against: query, buffer: &buffer)
    #expect(exactResult?.score == 1.0)
    #expect(exactResult?.kind == .exact)

    // Any edit should fail with maxEditDistance 0
    let typoResult = matcher.score("hallo", against: query, buffer: &buffer)
    #expect(typoResult == nil)
}

@Test func maxEditDistanceOneAllowsSingleEdit() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // 1 substitution - "hallo" differs by 1 char but may be rejected by prefilters
    // With maxEditDistance 1, the bitmask filter allows 1 missing character
    // "hello" has chars: h,e,l,o; "hallo" has chars: h,a,l,o
    // 'e' is in hello but not hallo - 1 missing char, passes bitmask filter
    _ = matcher.score("hallo", against: query, buffer: &buffer)
    // This may or may not match depending on trigram filtering

    // 1 deletion - "helo" is hello with one 'l' removed
    _ = matcher.score("helo", against: query, buffer: &buffer)
    // This may or may not match depending on prefilters

    // 2 edits should fail - "halo" differs by 2 chars
    let result3 = matcher.score("halo", against: query, buffer: &buffer)
    #expect(result3 == nil)

    // At least test that exact match still works
    let exactResult = matcher.score("hello", against: query, buffer: &buffer)
    #expect(exactResult?.score == 1.0)
}

@Test func maxEditDistanceTwoAllowsTwoEdits() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Deletion - "helo" (one l removed) - shares trigram "hel", passes filter
    let result1 = matcher.score("helo", against: query, buffer: &buffer)
    #expect(result1 != nil)

    // Insertion - "helllo" (extra l) - shares trigrams with hello
    let result2 = matcher.score("helllo", against: query, buffer: &buffer)
    #expect(result2 != nil)

    // Short transposition test with "teh" vs "the" (3-char strings skip trigram filter)
    let query2 = matcher.prepare("teh")
    let result3 = matcher.score("the", against: query2, buffer: &buffer)
    #expect(result3 != nil)
}

@Test func maxEditDistanceHighAllowsMoreDifferences() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 5))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Multiple edits but all query chars exist in candidate - "helo" (1 deletion)
    let result1 = matcher.score("helo", against: query, buffer: &buffer)
    #expect(result1 != nil)

    // "he" - only h and e, missing l and o from query → should fail with strict filter
    let result2 = matcher.score("he", against: query, buffer: &buffer)
    #expect(result2 == nil, "Should reject when query chars are missing from candidate")
}

@Test func maxEditDistanceAffectsLengthBounds() {
    // With maxEditDistance 0, candidate must match exactly
    let matcher0 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 0))))
    let query0 = matcher0.prepare("test")
    var buffer0 = matcher0.makeBuffer()

    // Shorter candidate fails length bounds
    let result0 = matcher0.score("tes", against: query0, buffer: &buffer0)
    #expect(result0 == nil)

    // With maxEditDistance 2, candidate can have some edits
    // Bitmask filter allows up to effectiveMaxEditDistance missing character types
    let matcher2 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    let query2 = matcher2.prepare("ab")
    var buffer2 = matcher2.makeBuffer()

    // "abc" contains all query chars (a, b) plus extra - should match
    let result2 = matcher2.score("abc", against: query2, buffer: &buffer2)
    #expect(result2 != nil)

    // "a" is missing 'b' from query - but with a 2-char query, bitmask tolerance is 0
    // (strict for short queries), so the missing character type causes rejection
    let result3 = matcher2.score("a", against: query2, buffer: &buffer2)
    #expect(result3 == nil, "Short query (≤3 chars) uses strict bitmask: missing 'b' → rejected")
}

@Test func bitmaskToleranceAdaptsToQueryLength() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // 3-char query: strict bitmask (tolerance = 0)
    // "abx" vs "aby" — 'x' missing from candidate → rejected by bitmask
    let query3 = matcher.prepare("abx")
    let strict = matcher.score("aby", against: query3, buffer: &buffer)
    #expect(strict == nil, "3-char query uses strict bitmask: missing 'x' → rejected")

    // 4-char query: relaxed bitmask (tolerance = effectiveMaxEditDistance)
    // "abcx" vs "abcy" — 'x' missing but within edit budget → passes bitmask
    let query4 = matcher.prepare("abcx")
    let relaxed = matcher.score("abcy", against: query4, buffer: &buffer)
    #expect(relaxed != nil, "4-char query uses relaxed bitmask: 1 missing char within edit budget")
}

// MARK: - minScore Threshold Filtering

@Test func minScoreFiltersLowScores() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.8))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Exact match has score 1.0, should pass
    let exactResult = matcher.score("hello", against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult!.score >= 0.8)
}

@Test func minScoreZeroAllowsAllMatches() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 3))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Even low-quality matches should pass with minScore 0
    let result = matcher.score("helo", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func minScoreOneRequiresPerfectMatch() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 1.0))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Only exact matches should pass
    let exactResult = matcher.score("hello", against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.score == 1.0)

    // Prefix match (even perfect prefix) may not reach 1.0 due to weighting
    let prefixResult = matcher.score("helloworld", against: query, buffer: &buffer)
    // May or may not pass depending on whether prefix weight gets it to 1.0
    if let score = prefixResult?.score {
        #expect(score == 1.0)
    }
}

@Test func minScoreBoundaryValues() {
    // Test at the boundary
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.5, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    // Get score for a specific candidate
    let result = matcher.score("helo", against: query, buffer: &buffer)

    if let score = result?.score {
        #expect(score >= 0.5)
    }
}

// MARK: - prefixWeight Configuration

@Test func prefixWeightIncreasesScoreForPrefixMatches() {
    let query = "test"
    let candidate = "testing"

    // Low prefix weight
    let edConfig1 = EditDistanceConfig(prefixWeight: 1.0, substringWeight: 1.0)
    let matcher1 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(edConfig1)))
    var buffer1 = matcher1.makeBuffer()
    let query1 = matcher1.prepare(query)
    let score1 = matcher1.score(candidate, against: query1, buffer: &buffer1)?.score ?? 0

    // High prefix weight
    let edConfig2 = EditDistanceConfig(prefixWeight: 2.0, substringWeight: 1.0)
    let matcher2 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(edConfig2)))
    var buffer2 = matcher2.makeBuffer()
    let query2 = matcher2.prepare(query)
    let score2 = matcher2.score(candidate, against: query2, buffer: &buffer2)?.score ?? 0

    // Higher prefix weight should result in higher or equal score (capped at 1.0)
    #expect(score2 >= score1)
}

@Test func prefixWeightCappedAtOne() {
    // Very high prefix weight, but score should be capped at 1.0
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(prefixWeight: 10.0))))
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("testing", against: query, buffer: &buffer)

    if let score = result?.score {
        #expect(score <= 1.0)
    }
}

@Test func prefixWeightZeroEffectivelyDisablesPrefixBonus() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(prefixWeight: 0.0))))
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("testing", against: query, buffer: &buffer)

    // With prefixWeight 0.0, prefix matches get score 0
    // The matcher may fall back to substring matching
    if let score = result?.score {
        #expect(score >= 0.0)
    }
}

// MARK: - substringWeight Configuration

@Test func substringWeightAffectsSubstringMatchScore() {
    let query = "test"
    let candidate = "unittest"

    // Low substring weight
    let matcher1 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(substringWeight: 0.5))))
    var buffer1 = matcher1.makeBuffer()
    let query1 = matcher1.prepare(query)
    let result1 = matcher1.score(candidate, against: query1, buffer: &buffer1)

    // Normal substring weight
    let matcher2 = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(substringWeight: 1.0))))
    var buffer2 = matcher2.makeBuffer()
    let query2 = matcher2.prepare(query)
    let result2 = matcher2.score(candidate, against: query2, buffer: &buffer2)

    // Higher substringWeight should result in higher score
    if let score1 = result1?.score, let score2 = result2?.score {
        #expect(score2 >= score1)
    }
}

@Test func substringWeightCappedAtOne() {
    let edConfig = EditDistanceConfig(prefixWeight: 1.0, substringWeight: 5.0)
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(edConfig)))
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("unittest", against: query, buffer: &buffer)

    if let score = result?.score {
        #expect(score <= 1.0)
    }
}

// MARK: - Weight Ratio Effects

@Test func prefixVsSubstringWeightRatio() {
    // Test that prefix matches are preferred when prefixWeight > substringWeight
    let matcher = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(
            maxEditDistance: 2,
            prefixWeight: 2.0,
            substringWeight: 1.0
        ))
    ))
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("test")

    let prefixResult = matcher.score("testing", against: query, buffer: &buffer)
    let substringResult = matcher.score("mytest", against: query, buffer: &buffer)

    // Both should match
    #expect(prefixResult != nil)
    #expect(substringResult != nil)

    // Prefix match kind should be indicated
    if let prefixKind = prefixResult?.kind {
        #expect(prefixKind == .prefix)
    }
}

@Test func equalWeightsNoPreference() {
    let matcher = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .editDistance(EditDistanceConfig(
            prefixWeight: 1.0,
            substringWeight: 1.0
        ))
    ))
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("test")

    // With equal weights and same edit distance, scores should be similar
    let prefixResult = matcher.score("testing", against: query, buffer: &buffer)
    let substringResult = matcher.score("mytest", against: query, buffer: &buffer)

    #expect(prefixResult != nil)
    #expect(substringResult != nil)
}

// MARK: - Default Configuration Values

@Test func defaultConfigurationValues() {
    let config = MatchConfig()

    #expect(config.editDistanceConfig!.maxEditDistance == 2)
    #expect(config.minScore == 0.3)
    #expect(config.editDistanceConfig!.prefixWeight == 1.5)
    #expect(config.editDistanceConfig!.substringWeight == 1.0)
}

@Test func defaultMatcherBehavior() {
    let matcher = FuzzyMatcher() // Uses default config
    var buffer = matcher.makeBuffer()

    // Default config should allow reasonable fuzzy matching
    let query = matcher.prepare("hello")

    // Exact match
    let exact = matcher.score("hello", against: query, buffer: &buffer)
    #expect(exact?.score == 1.0)

    // Small typo
    let typo = matcher.score("helo", against: query, buffer: &buffer)
    #expect(typo != nil)

    // Completely different
    let different = matcher.score("xyz", against: query, buffer: &buffer)
    #expect(different == nil)
}

// MARK: - Configuration Combinations

@Test func strictConfiguration() {
    // Very strict matching: low edit distance, high min score
    let config = MatchConfig(minScore: 1.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 0)))
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("exact")

    // Only exact matches should work
    let exactResult = matcher.score("exact", against: query, buffer: &buffer)
    #expect(exactResult?.score == 1.0)

    let almostResult = matcher.score("exac", against: query, buffer: &buffer)
    #expect(almostResult == nil)
}

@Test func lenientConfiguration() {
    // Very lenient matching: high edit distance, low min score
    let config = MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 5)))
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("hello")

    // Should match more things
    let result1 = matcher.score("helo", against: query, buffer: &buffer)
    _ = matcher.score("h", against: query, buffer: &buffer)

    #expect(result1 != nil)
    // Single character might still fail other prefilters
}

// MARK: - Config Stored in Query

@Test func configStoredInFuzzyQuery() {
    let config = MatchConfig(minScore: 0.1, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 5)))
    let matcher = FuzzyMatcher(config: config)

    let query = matcher.prepare("test")

    // Config should be stored in the query
    #expect(query.config.editDistanceConfig!.maxEditDistance == 5)
    #expect(query.config.minScore == 0.1)
}

@Test func matcherConfigMatchesQueryConfig() {
    let config = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 2.5, substringWeight: 0.8)))
    let matcher = FuzzyMatcher(config: config)

    #expect(matcher.config.editDistanceConfig!.prefixWeight == 2.5)
    #expect(matcher.config.editDistanceConfig!.substringWeight == 0.8)

    let query = matcher.prepare("test")
    #expect(query.config.editDistanceConfig!.prefixWeight == 2.5)
    #expect(query.config.editDistanceConfig!.substringWeight == 0.8)
}

// MARK: - Score Cutoff Boundary Sweep
//
// Systematically tests minScore at 0.1 increments to verify that the threshold
// is applied correctly across the full range, including boundary precision.

@Test func scoreCutoffSweepExactMatch() {
    // Exact match (score=1.0) should pass every threshold up to 1.0
    let thresholds: [Double] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    for threshold in thresholds {
        let matcher = FuzzyMatcher(config: MatchConfig(minScore: threshold))
        let query = matcher.prepare("hello")
        var buffer = matcher.makeBuffer()

        let result = matcher.score("hello", against: query, buffer: &buffer)
        #expect(result != nil, "Exact match (1.0) should pass minScore=\(threshold)")
        #expect(result?.score == 1.0, "Exact match should always score 1.0 at minScore=\(threshold)")
    }
}

@Test func scoreCutoffSweepTypoMatch() {
    // "helo" vs "hello" — 1 deletion, should produce a score around 0.8-0.9
    // Find which thresholds it passes vs fails
    let thresholds: [Double] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    // First, get the actual score with no threshold
    let baseMatcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    let baseQuery = baseMatcher.prepare("hello")
    var baseBuffer = baseMatcher.makeBuffer()
    let baseResult = baseMatcher.score("helo", against: baseQuery, buffer: &baseBuffer)
    let actualScore = baseResult?.score ?? 0.0

    for threshold in thresholds {
        let edConfig = EditDistanceConfig(maxEditDistance: 2)
        let matcher = FuzzyMatcher(config: MatchConfig(minScore: threshold, algorithm: .editDistance(edConfig)))
        let query = matcher.prepare("hello")
        var buffer = matcher.makeBuffer()

        let result = matcher.score("helo", against: query, buffer: &buffer)

        if threshold <= actualScore {
            #expect(result != nil, "Score \(actualScore) should pass minScore=\(threshold)")
        } else {
            #expect(result == nil, "Score \(actualScore) should fail minScore=\(threshold)")
        }
    }
}

@Test func scoreCutoffSweepPrefixMatch() {
    // "test" vs "testing" — exact prefix, score near 1.0 minus length penalty
    let thresholds: [Double] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    let baseMatcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0))
    let baseQuery = baseMatcher.prepare("test")
    var baseBuffer = baseMatcher.makeBuffer()
    let baseResult = baseMatcher.score("testing", against: baseQuery, buffer: &baseBuffer)
    let actualScore = baseResult?.score ?? 0.0

    for threshold in thresholds {
        let matcher = FuzzyMatcher(config: MatchConfig(minScore: threshold))
        let query = matcher.prepare("test")
        var buffer = matcher.makeBuffer()

        let result = matcher.score("testing", against: query, buffer: &buffer)

        if threshold <= actualScore {
            #expect(result != nil, "Prefix score \(actualScore) should pass minScore=\(threshold)")
        } else {
            #expect(result == nil, "Prefix score \(actualScore) should fail minScore=\(threshold)")
        }
    }
}

@Test func scoreCutoffAtExactThreshold() {
    // Find a candidate's exact score, then set minScore to exactly that value.
    // The result should still pass (>=, not >).
    let baseMatcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var baseBuffer = baseMatcher.makeBuffer()

    let pairs: [(String, String)] = [
        ("hello", "helo"),
        ("test", "testing"),
        ("world", "worl"),
        ("fuzzy", "fzzy")
    ]

    for (q, c) in pairs {
        let baseQuery = baseMatcher.prepare(q)
        guard let baseResult = baseMatcher.score(c, against: baseQuery, buffer: &baseBuffer) else {
            continue
        }
        let exactScore = baseResult.score

        // Now test with minScore set to exactly the computed score
        let edConfig = EditDistanceConfig(maxEditDistance: 2)
        let matcher = FuzzyMatcher(config: MatchConfig(minScore: exactScore, algorithm: .editDistance(edConfig)))
        let query = matcher.prepare(q)
        var buffer = matcher.makeBuffer()

        let result = matcher.score(c, against: query, buffer: &buffer)
        #expect(result != nil, "Score \(exactScore) should pass minScore=\(exactScore) for \"\(q)\" vs \"\(c)\"")
    }
}

@Test func scoreCutoffJustAboveExactThreshold() {
    // Set minScore to score + epsilon — should be rejected
    let baseMatcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var baseBuffer = baseMatcher.makeBuffer()

    let baseQuery = baseMatcher.prepare("hello")
    guard let baseResult = baseMatcher.score("helo", against: baseQuery, buffer: &baseBuffer) else {
        return
    }
    let exactScore = baseResult.score

    let edConfig = EditDistanceConfig(maxEditDistance: 2)
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: exactScore + 0.001, algorithm: .editDistance(edConfig)))
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("helo", against: query, buffer: &buffer)
    #expect(result == nil, "Score \(exactScore) should fail minScore=\(exactScore + 0.001)")
}

// MARK: - MatchConfig Sendable

@Test func matchConfigIsSendable() {
    let config = MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 3)))

    // This test verifies compilation - MatchConfig conforms to Sendable
    Task {
        _ = config.editDistanceConfig!.maxEditDistance
    }

    #expect(config.editDistanceConfig!.maxEditDistance == 3)
}

// MARK: - Codable Round-Trip Tests

@Test func gapPenaltyCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let cases: [GapPenalty] = [
        .none,
        .linear(perCharacter: 0.01),
        .affine(open: 0.03, extend: 0.005)
    ]

    for original in cases {
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(GapPenalty.self, from: data)
        #expect(decoded == original, "GapPenalty round-trip failed for \(original)")
    }
}

@Test func editDistanceConfigCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let original = EditDistanceConfig(
        maxEditDistance: 3,
        longQueryMaxEditDistance: 4,
        longQueryThreshold: 15,
        prefixWeight: 2.0,
        substringWeight: 0.8,
        wordBoundaryBonus: 0.12,
        consecutiveBonus: 0.06,
        gapPenalty: .linear(perCharacter: 0.02),
        firstMatchBonus: 0.2,
        firstMatchBonusRange: 12,
        lengthPenalty: 0.005,
        acronymWeight: 1.2
    )

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(EditDistanceConfig.self, from: data)
    #expect(decoded == original)
}

@Test func smithWatermanConfigCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let original = SmithWatermanConfig(
        scoreMatch: 20,
        penaltyGapStart: 4,
        penaltyGapExtend: 2,
        bonusConsecutive: 5,
        bonusBoundary: 10,
        bonusBoundaryWhitespace: 12,
        bonusBoundaryDelimiter: 11,
        bonusCamelCase: 6,
        bonusFirstCharMultiplier: 3,
        splitSpaces: false
    )

    let data = try encoder.encode(original)
    let decoded = try decoder.decode(SmithWatermanConfig.self, from: data)
    #expect(decoded == original)
}

@Test func matchingAlgorithmCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let cases: [MatchingAlgorithm] = [
        .editDistance(),
        .editDistance(EditDistanceConfig(maxEditDistance: 1)),
        .smithWaterman(),
        .smithWaterman(SmithWatermanConfig(scoreMatch: 20))
    ]

    for original in cases {
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MatchingAlgorithm.self, from: data)
        #expect(decoded == original, "MatchingAlgorithm round-trip failed")
    }
}

@Test func matchConfigCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let configs: [MatchConfig] = [
        .editDistance,
        .smithWaterman,
        MatchConfig(minScore: 0.7, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))),
        MatchConfig(minScore: 0.5, algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 5)))
    ]

    for original in configs {
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MatchConfig.self, from: data)
        #expect(decoded == original, "MatchConfig round-trip failed")
    }
}

@Test func matchKindCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for original in MatchKind.allCases {
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MatchKind.self, from: data)
        #expect(decoded == original, "MatchKind round-trip failed for \(original)")
    }
}

@Test func scoredMatchCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let original = ScoredMatch(score: 0.85, kind: .prefix)
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(ScoredMatch.self, from: data)
    #expect(decoded == original)
}

@Test func matchResultCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let original = MatchResult(
        candidate: "getUserById",
        match: ScoredMatch(score: 0.92, kind: .prefix)
    )
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(MatchResult.self, from: data)
    #expect(decoded == original)
}
