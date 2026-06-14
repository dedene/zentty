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

// MARK: - Basic Scoring

@Test func swExactMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("user", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swExactMatchCaseInsensitive() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("User", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swNoMatchMissingCharacter() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("xyz")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result == nil)
}

@Test func swEmptyQuery() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swEmptyCandidate() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("", against: query, buffer: &buffer)

    #expect(result == nil)
}

// MARK: - Score Normalization

@Test func swScoreInZeroToOneRange() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("get")
    var buffer = matcher.makeBuffer()

    let candidates = ["getUserById", "getUsername", "target", "debugging", "great"]
    for candidate in candidates {
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            #expect(result.score >= 0.0, "Score should be >= 0.0 for \(candidate)")
            #expect(result.score <= 1.0, "Score should be <= 1.0 for \(candidate)")
        }
    }
}

// MARK: - Match Kind

@Test func swAlignmentMatchKind() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    // Use a query longer than word count so acronym fallback doesn't fire
    let query = matcher.prepare("getuser")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .alignment)
}

@Test func swExactMatchKindForPerfectMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result?.score == 1.0)
}

// MARK: - Boundary and CamelCase Bonuses

@Test func swBoundaryMatchScoresHigher() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("gu")
    var buffer = matcher.makeBuffer()

    // "gu" matches at word boundaries in get_user: 'g' at 0 (boundary), 'u' at 4 (boundary)
    let boundaryResult = matcher.score("get_user", against: query, buffer: &buffer)
    // "gu" matches contiguously in "argument" at positions 2,3 (no boundaries)
    let noBoundaryResult = matcher.score("argument", against: query, buffer: &buffer)

    #expect(boundaryResult != nil)
    #expect(noBoundaryResult != nil)
    #expect(boundaryResult!.score > noBoundaryResult!.score,
            "Boundary match should score higher")
}

@Test func swCamelCaseTransitionBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("gb")
    var buffer = matcher.makeBuffer()

    // "gB" has camelCase at 'B' in getById
    let camelResult = matcher.score("getById", against: query, buffer: &buffer)

    #expect(camelResult != nil)
    #expect(camelResult!.score > 0.0)
}

// MARK: - Consecutive Bonus

@Test func swConsecutiveMatchScoresHigher() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    // Consecutive match
    let consecutive = matcher.score("abcdef", against: query, buffer: &buffer)
    // Scattered match
    let scattered = matcher.score("axbxcx", against: query, buffer: &buffer)

    #expect(consecutive != nil)
    #expect(scattered != nil)
    #expect(consecutive!.score > scattered!.score,
            "Consecutive match should score higher than scattered")
}

// MARK: - Gap Penalties

@Test func swLargerGapReducesScore() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ac")
    var buffer = matcher.makeBuffer()

    let smallGap = matcher.score("abc", against: query, buffer: &buffer)
    let largeGap = matcher.score("axxxxc", against: query, buffer: &buffer)

    #expect(smallGap != nil)
    #expect(largeGap != nil)
    #expect(smallGap!.score > largeGap!.score,
            "Smaller gap should score higher")
}

// MARK: - First Char Multiplier

@Test func swFirstCharBonusMultiplied() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("g")
    var buffer = matcher.makeBuffer()

    // 'g' at a word boundary position 0
    let result = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
}

// MARK: - Prefilter Integration

@Test func swBitmaskPrefilterRejectsMissingChars() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("xyz")
    var buffer = matcher.makeBuffer()

    // No x, y, or z present
    let result = matcher.score("abcdefg", against: query, buffer: &buffer)

    #expect(result == nil, "Missing characters should be rejected by bitmask prefilter")
}

@Test func swPartialCharOverlapRejects() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abz")
    var buffer = matcher.makeBuffer()

    // Has 'a' and 'b' but not 'z'
    let result = matcher.score("abcdef", against: query, buffer: &buffer)

    #expect(result == nil, "SW with tolerance 0 should reject when any char is missing")
}

// MARK: - Buffer Reuse

@Test func swBufferReuseProducesConsistentResults() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("get")
    var buffer = matcher.makeBuffer()

    let firstResult = matcher.score("getUserById", against: query, buffer: &buffer)
    let secondResult = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(firstResult != nil)
    #expect(secondResult != nil)
    #expect(firstResult!.score == secondResult!.score,
            "Reusing buffer should produce identical results")
}

@Test func swBufferReuseAcrossDifferentCandidates() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()

    let candidates = ["getUserById", "userService", "setUser", "fetchUserData"]
    var results: [Double] = []

    for candidate in candidates {
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            results.append(result.score)
        }
    }

    // Re-run and verify same results
    var results2: [Double] = []
    for candidate in candidates {
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            results2.append(result.score)
        }
    }

    #expect(results == results2, "Buffer reuse should produce identical results across runs")
}

// MARK: - MinScore Threshold

@Test func swMinScoreFilters() {
    let config = MatchConfig(minScore: 0.8, algorithm: .smithWaterman())
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    // Very scattered match should be below threshold
    let result = matcher.score("axxxxxxxxxxxxxxxxb", against: query, buffer: &buffer)

    // Either nil (filtered) or score >= 0.8
    if let r = result {
        #expect(r.score >= 0.8)
    }
}

// MARK: - Ranking Quality

@Test func swPrefixMatchRanksHigher() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("get")
    var buffer = matcher.makeBuffer()

    let prefix = matcher.score("getUser", against: query, buffer: &buffer)
    let substring = matcher.score("targetMethod", against: query, buffer: &buffer)

    #expect(prefix != nil)
    if let sub = substring {
        #expect(prefix!.score > sub.score,
                "Prefix match should rank higher than scattered substring")
    }
}

@Test func swCamelCaseAbbreviationRanking() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    // "gubi" matches all word initials of getUserById via acronym fallback
    let getUserById = matcher.score("getUserById", against: query, buffer: &buffer)
    // "gubi" scattered in "debuggingStubItem" — no clean acronym initials match
    let scattered = matcher.score("debuggingStubItem", against: query, buffer: &buffer)

    #expect(getUserById != nil)
    #expect(scattered != nil)
    #expect(getUserById!.score > scattered!.score,
            "\"gubi\" with acronym match should score higher than scattered SW match")
}

@Test func swShorterCandidateDoesNotOverpenalize() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()

    let short = matcher.score("user", against: query, buffer: &buffer)
    let long = matcher.score("userServiceManagerFactory", against: query, buffer: &buffer)

    #expect(short != nil)
    #expect(long != nil)
    #expect(short!.score >= long!.score,
            "Exact match should score at least as high as longer candidate")
}

// MARK: - Backward Compatibility

@Test func swEditDistanceDefaultUnchanged() {
    // Default matcher should still use edit distance
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(result != nil)
    // ED mode should NOT return .alignment
    #expect(result?.kind != .alignment)
}

// MARK: - Convenience API

@Test func swConvenienceScore() {
    let matcher = FuzzyMatcher(config: .smithWaterman)

    let result = matcher.score("getUserById", against: "gubi")

    #expect(result != nil)
    #expect(result!.score > 0.0)
}

@Test func swTopMatches() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("get")

    let candidates = ["getUserById", "getUsername", "setUser", "fetchData", "targetMethod"]
    let results = matcher.topMatches(candidates, against: query, limit: 3)

    #expect(results.count <= 3)
    // Results should be sorted by score descending
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

@Test func swMatchesAll() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("user")

    let candidates = ["getUserById", "userService", "fetchData"]
    let results = matcher.matches(candidates, against: query)

    // All matching candidates should be returned, sorted
    #expect(results.count >= 1)
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

// MARK: - Custom Config

@Test func swCustomScoringConfig() {
    let customSW = SmithWatermanConfig(
        scoreMatch: 20,
        penaltyGapStart: 5,
        penaltyGapExtend: 2,
        bonusConsecutive: 6,
        bonusBoundary: 10,
        bonusCamelCase: 7,
        bonusFirstCharMultiplier: 3
    )
    let config = MatchConfig(algorithm: .smithWaterman(customSW))
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("get")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
    #expect(result!.score <= 1.0)
}

// MARK: - Single Character Query

@Test func swSingleCharQuery() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("g")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
    #expect(result!.score <= 1.0)
}

@Test func swSingleCharExactMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("a", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

// MARK: - Long Strings

@Test func swLongCandidate() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let longCandidate = String(repeating: "x", count: 200) + "abc" + String(repeating: "y", count: 200)
    let result = matcher.score(longCandidate, against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
}

// MARK: - Preset Config

@Test func swPresetConfig() {
    let config = MatchConfig.smithWaterman
    #expect(config.smithWatermanConfig != nil)
    #expect(config.smithWatermanConfig == .default)
}

// MARK: - Multi-Word Queries

@Test func swMultiWordBasicMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("johnson johnson")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)

    #expect(result != nil, "Multi-word query should match when both words are present")
    #expect(result!.score > 0.0)
    #expect(result?.kind == .alignment)
}

@Test func swMultiWordTypoMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("johsnon johnson")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)

    #expect(result != nil, "Multi-word query with transposition should still match")
    #expect(result!.score > 0.0)
}

@Test func swMultiWordANDSemantics() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("apple banana")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("apple pie", against: query, buffer: &buffer)

    #expect(result == nil, "Should return nil when second word is not found")
}

@Test func swMultiWordANDSemanticsBothMissing() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("xyz abc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello world", against: query, buffer: &buffer)

    #expect(result == nil, "Should return nil when no words match")
}

@Test func swSingleWordUnchanged() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let querySingle = matcher.prepare("johnson")
    var buffer = matcher.makeBuffer()

    // Single-word query should produce same results as before
    let result = matcher.score("Johnson & Johnson", against: querySingle, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
    #expect(querySingle.atoms.isEmpty, "Single-word query should have no atoms")
}

@Test func swMultiWordLeadingTrailingSpaces() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("  johnson  johnson  ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)

    #expect(result != nil, "Leading/trailing spaces should be trimmed from atoms")
    #expect(query.atoms.count == 2, "Should produce exactly 2 atoms")
}

@Test func swMultiWordBufferReuse() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("johnson johnson")
    var buffer = matcher.makeBuffer()

    let first = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)
    let second = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)

    #expect(first != nil)
    #expect(second != nil)
    #expect(first!.score == second!.score, "Buffer reuse should produce identical results")
}

@Test func swMultiWordScoreRange() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("procter gamble")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Procter & Gamble", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score >= 0.0)
    #expect(result!.score <= 1.0)
}

@Test func swMultiWordAtomsProperty() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("foo bar baz")

    #expect(query.atoms.count == 3)
}

@Test func swNonSWMultiWordNoAtoms() {
    // Edit distance mode should not create atoms even with spaces
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("foo bar")

    #expect(query.atoms.isEmpty, "Non-SW mode should not split into atoms")
}

@Test func swSplitSpacesDisabled() {
    let config = MatchConfig(
        algorithm: .smithWaterman(SmithWatermanConfig(splitSpaces: false))
    )
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("foo bar")

    #expect(query.atoms.isEmpty, "splitSpaces: false should disable atom splitting")
}

// MARK: - Acronym Fallback in SW Mode

@Test func swAcronymMatchesBristolMyersSquibb() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)

    #expect(result != nil, "Acronym 'bms' should match 'Bristol-Myers Squibb'")
    #expect(result?.kind == .acronym)
    #expect(result!.score >= 0.3)
}

@Test func swAcronymMatchesGeneralMotors() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("gmc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("General Motors Co", against: query, buffer: &buffer)

    #expect(result != nil, "Acronym 'gmc' should match 'General Motors Co'")
    #expect(result?.kind == .acronym)
}

@Test func swAcronymMatchesGeneralDynamics() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("gdc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("General Dynamics Corp", against: query, buffer: &buffer)

    #expect(result != nil, "Acronym 'gdc' should match 'General Dynamics Corp'")
    #expect(result?.kind == .acronym)
}

@Test func swAcronymMatchesJohnsonAndJohnson() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("jnj")
    var buffer = matcher.makeBuffer()

    // "jnj" matches via SW alignment (j→J, n→n, j→J) but NOT as acronym
    // because word initials include non-letter chars (j, &, space, j)
    let result = matcher.score("Johnson & Johnson", against: query, buffer: &buffer)

    #expect(result != nil, "'jnj' should match 'Johnson & Johnson' via SW alignment")
    #expect(result?.kind == .alignment)
}

@Test func swAcronymBeatsScatteredSWMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()

    let acronymResult = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    // A scattered SW match in a long name (if it even matches)
    let scatteredResult = matcher.score("UBS BBG MSCI Euro", against: query, buffer: &buffer)

    #expect(acronymResult != nil)
    if let scattered = scatteredResult {
        #expect(acronymResult!.score > scattered.score,
                "Acronym match should beat scattered SW match")
    }
}

@Test func swAcronymDoesNotFireForLongQueries() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("longquery1")  // 10 chars, > 8
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Lively Open Nested Generic Query Utility Extension Resource Y 1",
                               against: query, buffer: &buffer)

    // Should not produce .acronym for queries > 8 chars
    if let r = result {
        #expect(r.kind != .acronym)
    }
}

@Test func swAcronymBufferReuse() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()

    let first = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    let second = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)

    #expect(first != nil)
    #expect(second != nil)
    #expect(first!.score == second!.score, "Buffer reuse should produce identical acronym results")
    #expect(first!.kind == second!.kind)
}

@Test func swAcronymTakesMaxWithSW() {
    // When SW also matches, the higher score should win
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("tfs")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Thermo Fisher Scientific", against: query, buffer: &buffer)

    #expect(result != nil, "Should match via acronym or SW")
    #expect(result!.score >= 0.3)
}

// MARK: - A. Direct DP State Verification

@Test func swDPSingleCharMatch() {
    // "a" vs "a" with position-0 whitespace bonus (10)
    // Expected: scoreMatch + posBonus * firstCharMultiplier = 16 + 10*2 = 36
    let queryBytes: [UInt8] = [0x61]
    let candidateBytes: [UInt8] = [0x61]
    let bonusValues: [Int32] = [10]
    var state = SmithWatermanState(maxQueryLength: 1)

    let result = smithWatermanScore(
        query: queryBytes,
        candidate: candidateBytes,
        bonus: bonusValues,
        state: &state,
        config: .default
    )

    #expect(result == 36, "Single char match: 16 + 10*2 = 36")
}

@Test func swDPTwoCharConsecutive() {
    // "ab" vs "ab" with bonuses [10, 0]
    // 'a' at j=0: 16 + 10*2 = 36, bonus carried = 10
    // 'b' consecutive: carriedBonus = max(10, 4) = 10, effective = max(10, 0) = 10
    //   fromConsecutive = 36 + 16 + 10 = 62
    let queryBytes: [UInt8] = [0x61, 0x62]
    let candidateBytes: [UInt8] = [0x61, 0x62]
    let bonusValues: [Int32] = [10, 0]
    var state = SmithWatermanState(maxQueryLength: 2)

    let result = smithWatermanScore(
        query: queryBytes,
        candidate: candidateBytes,
        bonus: bonusValues,
        state: &state,
        config: .default
    )

    #expect(result == 62, "Two consecutive chars: 36 + 16 + 10 = 62")
}

@Test func swDPDiagonalCarry() {
    // "ab" vs "xab" with bonuses [10, 0, 0]
    // 'a' matches at position 1 (posBonus=0): 16 + 0*2 = 16
    // 'b' consecutive: carriedBonus = max(0, 4) = 4, effective = max(4, 0) = 4
    //   fromConsecutive = 16 + 16 + 4 = 36
    let queryBytes: [UInt8] = [0x61, 0x62]
    let candidateBytes: [UInt8] = [0x78, 0x61, 0x62]
    let bonusValues: [Int32] = [10, 0, 0]
    var state = SmithWatermanState(maxQueryLength: 2)

    let result = smithWatermanScore(
        query: queryBytes,
        candidate: candidateBytes,
        bonus: bonusValues,
        state: &state,
        config: .default
    )

    #expect(result == 36, "Diagonal carry: match starts at position 1, 16 + 16 + 4 = 36")
}

@Test func swDPNoMatch() {
    // "a" vs "xxx" — no character matches, score should be 0
    let queryBytes: [UInt8] = [0x61]
    let candidateBytes: [UInt8] = [0x78, 0x78, 0x78]
    let bonusValues: [Int32] = [10, 0, 0]
    var state = SmithWatermanState(maxQueryLength: 1)

    let result = smithWatermanScore(
        query: queryBytes,
        candidate: candidateBytes,
        bonus: bonusValues,
        state: &state,
        config: .default
    )

    #expect(result == 0, "No match should return 0")
}

@Test func swDPBestFromLastColumn() {
    // "ab" vs "abab" with bonuses [10, 0, 0, 0]
    // Best match comes from first "ab" pair: 36 + 16 + 10 = 62
    // Second "ab" pair starts without whitespace bonus, scores lower
    let queryBytes: [UInt8] = [0x61, 0x62]
    let candidateBytes: [UInt8] = [0x61, 0x62, 0x61, 0x62]
    let bonusValues: [Int32] = [10, 0, 0, 0]
    var state = SmithWatermanState(maxQueryLength: 2)

    let result = smithWatermanScore(
        query: queryBytes,
        candidate: candidateBytes,
        bonus: bonusValues,
        state: &state,
        config: .default
    )

    #expect(result == 62, "Best score from last column should be 62")
}

// MARK: - B. Multi-Byte Character Tests

@Test func swLatinExtendedCaseFolding() {
    // "café" should match "CAFÉ" via SW (Latin-1 Supplement: é/É)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("caf\u{E9}")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("CAF\u{C9}", against: query, buffer: &buffer)

    #expect(result != nil, "Latin Extended case folding should match")
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swGreekCaseFolding() {
    // "σπ" should match "ΣΠ" (Σ→σ via CE A3→CF 83, Π→π via CE A0→CF 80)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("\u{3C3}\u{3C0}")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("\u{3A3}\u{3A0}", against: query, buffer: &buffer)

    #expect(result != nil, "Greek case folding should match")
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swCyrillicCaseFolding() {
    // "бд" should match "БД" (Б→б via D0 91→D0 B1, Д→д via D0 94→D0 B4)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("\u{431}\u{434}")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("\u{411}\u{414}", against: query, buffer: &buffer)

    #expect(result != nil, "Cyrillic case folding should match")
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swMultiByteBonusTierDirect() {
    let sw = SmithWatermanConfig.default
    let boundary = Int32(sw.bonusBoundary)
    let whitespace = Int32(sw.bonusBoundaryWhitespace)
    let delimiter = Int32(sw.bonusBoundaryDelimiter)

    // After space → whitespace tier
    #expect(multiByteBonusTier(
        prevByte: 0x20,
        bonusBoundary: boundary,
        bonusBoundaryWhitespace: whitespace,
        bonusBoundaryDelimiter: delimiter
    ) == whitespace)

    // After '/' → delimiter tier
    #expect(multiByteBonusTier(
        prevByte: 0x2F,
        bonusBoundary: boundary,
        bonusBoundaryWhitespace: whitespace,
        bonusBoundaryDelimiter: delimiter
    ) == delimiter)

    // After ':' → delimiter tier
    #expect(multiByteBonusTier(
        prevByte: 0x3A,
        bonusBoundary: boundary,
        bonusBoundaryWhitespace: whitespace,
        bonusBoundaryDelimiter: delimiter
    ) == delimiter)

    // After 'a' (alnum) → 0
    #expect(multiByteBonusTier(
        prevByte: 0x61,
        bonusBoundary: boundary,
        bonusBoundaryWhitespace: whitespace,
        bonusBoundaryDelimiter: delimiter
    ) == 0)

    // After '-' (non-alnum, non-whitespace, non-delimiter) → boundary
    #expect(multiByteBonusTier(
        prevByte: 0x2D,
        bonusBoundary: boundary,
        bonusBoundaryWhitespace: whitespace,
        bonusBoundaryDelimiter: delimiter
    ) == boundary)
}

@Test func swMixedASCIIAndMultiByte() {
    // "café" matched against "CAFÉ" — mixed ASCII and Latin-1 Supplement
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("caf\u{E9}")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("CAF\u{C9}", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0, "Mixed ASCII + multi-byte should match exactly")
}

// MARK: - C. Score Normalization Verification

@Test func swNormalizationLen1() {
    // maxScore = queryLen × scoreMatch + bonusBoundaryWhitespace × (firstCharMultiplier + queryLen - 1)
    // = 1*16 + 10*(2+1-1) = 16 + 20 = 36
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("a")

    #expect(query.maxSmithWatermanScore == 36)
}

@Test func swNormalizationLen3() {
    // = 3*16 + 10*(2+3-1) = 48 + 40 = 88
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")

    #expect(query.maxSmithWatermanScore == 88)
}

@Test func swNormalizationLen8() {
    // = 8*16 + 10*(2+8-1) = 128 + 90 = 218
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abcdefgh")

    #expect(query.maxSmithWatermanScore == 218)
}

@Test func swNormalizationClamped() {
    // Verify score is always in [0.0, 1.0] even with extreme config
    let extreme = SmithWatermanConfig(
        scoreMatch: 100,
        penaltyGapStart: 0,
        penaltyGapExtend: 0,
        bonusConsecutive: 50,
        bonusBoundary: 80,
        bonusBoundaryWhitespace: 100,
        bonusCamelCase: 60,
        bonusFirstCharMultiplier: 5
    )
    let config = MatchConfig(minScore: 0.0, algorithm: .smithWaterman(extreme))
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let candidates = ["abc", "ABC", "a_b_c", "xaxbxc", "abcdef"]
    for candidate in candidates {
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            #expect(result.score >= 0.0, "Score must be >= 0.0 for \(candidate)")
            #expect(result.score <= 1.0, "Score must be <= 1.0 for \(candidate)")
        }
    }
}

// MARK: - D. Delimiter/Boundary Classification

@Test func swDelimiterSlash() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("b")
    var buffer = matcher.makeBuffer()

    let delimiterResult = matcher.score("a/b", against: query, buffer: &buffer)
    let midWordResult = matcher.score("axb", against: query, buffer: &buffer)

    #expect(delimiterResult != nil)
    #expect(midWordResult != nil)
    #expect(delimiterResult!.score > midWordResult!.score,
            "After '/' delimiter should score higher than mid-word")
}

@Test func swDelimiterColon() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("b")
    var buffer = matcher.makeBuffer()

    let delimiterResult = matcher.score("a:b", against: query, buffer: &buffer)
    let midWordResult = matcher.score("axb", against: query, buffer: &buffer)

    #expect(delimiterResult != nil)
    #expect(midWordResult != nil)
    #expect(delimiterResult!.score > midWordResult!.score,
            "After ':' delimiter should score higher than mid-word")
}

@Test func swDelimiterSemicolonPipe() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("b")
    var buffer = matcher.makeBuffer()

    let semicolonResult = matcher.score("a;b", against: query, buffer: &buffer)
    let pipeResult = matcher.score("a|b", against: query, buffer: &buffer)
    let midWordResult = matcher.score("axb", against: query, buffer: &buffer)

    #expect(semicolonResult != nil)
    #expect(pipeResult != nil)
    #expect(midWordResult != nil)
    #expect(semicolonResult!.score > midWordResult!.score,
            "After ';' delimiter should score higher than mid-word")
    #expect(pipeResult!.score > midWordResult!.score,
            "After '|' delimiter should score higher than mid-word")
}

@Test func swPosition0WhitespaceBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let pos0Result = matcher.score("abc", against: query, buffer: &buffer)
    let laterResult = matcher.score("xxxa", against: query, buffer: &buffer)

    #expect(pos0Result != nil)
    #expect(laterResult != nil)
    #expect(pos0Result!.score > laterResult!.score,
            "Position 0 (whitespace bonus) should score higher")
}

@Test func swAfterSpaceBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("b")
    var buffer = matcher.makeBuffer()

    let afterSpaceResult = matcher.score("foo bar", against: query, buffer: &buffer)
    let midWordResult = matcher.score("fooXbar", against: query, buffer: &buffer)

    #expect(afterSpaceResult != nil)
    #expect(midWordResult != nil)
    #expect(afterSpaceResult!.score > midWordResult!.score,
            "After space should score higher than mid-word")
}

@Test func swNonDigitToDigitBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("3")
    var buffer = matcher.makeBuffer()

    // non-digit→digit triggers camelCase tier
    let digitBoundary = matcher.score("foo3", against: query, buffer: &buffer)
    // digit→digit — no bonus
    let digitAfterDigit = matcher.score("123", against: query, buffer: &buffer)

    #expect(digitBoundary != nil)
    #expect(digitAfterDigit != nil)
    #expect(digitBoundary!.score > digitAfterDigit!.score,
            "Non-digit→digit transition should trigger camelCase bonus")
}

// MARK: - E. Config Parameter Isolation

@Test func swConfigScoreMatchIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(scoreMatch: 8))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(scoreMatch: 32))
    ))

    let queryLow = low.prepare("abc")
    let queryHigh = high.prepare("abc")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    let lowResult = low.score("abcdef", against: queryLow, buffer: &bufLow)
    let highResult = high.score("abcdef", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    // Both normalize to 0-1 using their own maxScore, so compare with a gapped match
    let lowGapped = low.score("axxbxxc", against: queryLow, buffer: &bufLow)
    let highGapped = high.score("axxbxxc", against: queryHigh, buffer: &bufHigh)

    // Higher scoreMatch makes gap penalty relatively smaller
    if let lg = lowGapped, let hg = highGapped {
        #expect(hg.score > lg.score,
                "Higher scoreMatch should make gap penalty relatively smaller")
    }
}

@Test func swConfigGapStartIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 1))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 8))
    ))

    let queryLow = low.prepare("ac")
    let queryHigh = high.prepare("ac")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    let lowResult = low.score("axxc", against: queryLow, buffer: &bufLow)
    let highResult = high.score("axxc", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(lowResult!.score > highResult!.score,
            "Higher penaltyGapStart should reduce score for gapped match")
}

@Test func swConfigGapExtendIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapExtend: 0))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapExtend: 4))
    ))

    let queryLow = low.prepare("ac")
    let queryHigh = high.prepare("ac")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    // Long gap to see extend penalty effect
    let lowResult = low.score("axxxxxxc", against: queryLow, buffer: &bufLow)
    let highResult = high.score("axxxxxxc", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(lowResult!.score > highResult!.score,
            "Higher penaltyGapExtend should reduce score for long gaps")
}

@Test func swConfigConsecutiveIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusConsecutive: 0))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusConsecutive: 10))
    ))

    let queryLow = low.prepare("abc")
    let queryHigh = high.prepare("abc")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    let lowResult = low.score("xabcx", against: queryLow, buffer: &bufLow)
    let highResult = high.score("xabcx", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(highResult!.score > lowResult!.score,
            "Higher bonusConsecutive should increase score for consecutive matches")
}

@Test func swConfigBoundaryIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusBoundary: 0))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusBoundary: 20))
    ))

    let queryLow = low.prepare("b")
    let queryHigh = high.prepare("b")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    // Match 'b' after underscore (non-word boundary → bonusBoundary tier)
    let lowResult = low.score("a_b", against: queryLow, buffer: &bufLow)
    let highResult = high.score("a_b", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(highResult!.score > lowResult!.score,
            "Higher bonusBoundary should increase score for boundary matches")
}

@Test func swConfigCamelCaseIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusCamelCase: 0))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusCamelCase: 15))
    ))

    let queryLow = low.prepare("b")
    let queryHigh = high.prepare("b")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    // Match 'B' at camelCase transition (lowercase → uppercase)
    let lowResult = low.score("aB", against: queryLow, buffer: &bufLow)
    let highResult = high.score("aB", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(highResult!.score > lowResult!.score,
            "Higher bonusCamelCase should increase score for camelCase matches")
}

@Test func swConfigFirstCharMultiplierIsolation() {
    let low = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusFirstCharMultiplier: 1))
    ))
    let high = FuzzyMatcher(config: MatchConfig(
        minScore: 0.0,
        algorithm: .smithWaterman(SmithWatermanConfig(bonusFirstCharMultiplier: 5))
    ))

    let queryLow = low.prepare("a")
    let queryHigh = high.prepare("a")
    var bufLow = low.makeBuffer()
    var bufHigh = high.makeBuffer()

    // Match 'a' at a non-boundary position (e.g., mid-word in "xxxa").
    // Higher multiplier raises the theoretical max (maxSmithWatermanScore) while
    // the actual raw score stays the same (no boundary bonus), so the normalized
    // score decreases — verifying the multiplier's directional effect.
    let lowResult = low.score("xxxa", against: queryLow, buffer: &bufLow)
    let highResult = high.score("xxxa", against: queryHigh, buffer: &bufHigh)

    #expect(lowResult != nil)
    #expect(highResult != nil)
    #expect(lowResult!.score > highResult!.score,
            "Higher firstCharMultiplier should lower score for non-boundary match (higher theoretical max)")
}

// MARK: - F. Acronym Fallback Boundaries

@Test func swAcronymLen2Minimum() {
    // 2-char query against 3+ word candidate → acronym should fire
    // Use long words so SW gap penalties make alignment score lose to acronym
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    let result = matcher.score(
        "Axxxxxxxxxxxxxxxxxxx Bxxxxxxxxxxxxxxxxxxx Cxxxxxxxxxxxxxxxxxxx",
        against: query, buffer: &buffer
    )

    #expect(result != nil)
    #expect(result?.kind == .acronym, "2-char query with 3+ words should fire acronym")
}

@Test func swAcronymLen8Maximum() {
    // 8-char query against 9 word candidate → acronym should fire
    // Words must be short enough that 8+ boundaries fit in the first 64 chars
    // of the boundary mask (each word+space ≤ 8 chars → ≤ 64 total).
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abcdefgh")
    var buffer = matcher.makeBuffer()

    let result = matcher.score(
        "Axxxxxx Bxxxxxx Cxxxxxx Dxxxxxx Exxxxxx Fxxxxxx Gxxxxxx Hxxxxxx Ixxxxxx",
        against: query, buffer: &buffer
    )

    #expect(result != nil)
    #expect(result?.kind == .acronym, "8-char query with 8+ words should fire acronym")
}

@Test func swAcronymLen9NoFire() {
    // 9-char query → should NOT produce .acronym (max is 8)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abcdefghi")
    var buffer = matcher.makeBuffer()

    let result = matcher.score(
        "Axxxxxx Bxxxxxx Cxxxxxx Dxxxxxx Exxxxxx Fxxxxxx Gxxxxxx Hxxxxxx Ixxxxxx",
        against: query, buffer: &buffer
    )

    if let r = result {
        #expect(r.kind != .acronym, "9-char query should not fire acronym")
    }
}

@Test func swAcronymLen1NoFire() {
    // 1-char query → should NOT produce .acronym (min is 2)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Alpha Beta Charlie", against: query, buffer: &buffer)

    if let r = result {
        #expect(r.kind != .acronym, "1-char query should not fire acronym")
    }
}

@Test func swAcronymExactly3Words() {
    // 3-char query, exactly 3 words → acronym should fire (minimum word count)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Alpha Beta Charlie", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .acronym, "3-char query with exactly 3 words should fire acronym")
}

@Test func swAcronym2WordsNoFire() {
    // 2-char query, 2 words → should NOT fire acronym (needs wordCount >= 3)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Axxxxxxxxxxxxxxxxxxx Bxxxxxxxxxxxxxxxxxxx", against: query, buffer: &buffer)

    if let r = result {
        #expect(r.kind != .acronym,
                "2-char query with only 2 words should not fire acronym (needs >= 3 words)")
    }
}

// MARK: - G. Additional Edge Cases

@Test func swBothEmpty() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func swQueryLongerThanCandidate() {
    // Long query, short candidate — bitmask should reject (tolerance 0)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abcdefghij")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    #expect(result == nil, "Query much longer than candidate should be rejected by bitmask prefilter")
}

@Test func swMinScoreBoundary() {
    let config = MatchConfig(minScore: 0.9, algorithm: .smithWaterman())
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    // Scattered match should be below 0.9
    let scattered = matcher.score("axxbxxcxx", against: query, buffer: &buffer)

    if let r = scattered {
        #expect(r.score >= 0.9, "If returned, score must be above minScore threshold")
    }

    // Exact match should pass
    let exact = matcher.score("abc", against: query, buffer: &buffer)
    #expect(exact != nil, "Exact match should pass any minScore threshold")
    #expect(exact?.score == 1.0)
}
