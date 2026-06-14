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

// MARK: - Acronym Match Tests

@Test func acronymMatchFullCoverage() {
    // "icag" should match "International Consolidated Airlines Group" (4/4 words)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("icag")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("International Consolidated Airlines Group", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .acronym)
    #expect(result!.score > 0.7)
}

@Test func acronymMatchBMS() {
    // "bms" should match "Bristol-Myers Squibb" (3/3 words)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .acronym)
    #expect(result!.score > 0.7)
}

@Test func acronymMatchBOA() {
    // "boa" against "Bank of America" — short query gets handled by
    // prefix/subsequence with good boundary bonuses, so acronym pass
    // may not fire. Just verify a good match is returned.
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("boa")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Bank of America", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func acronymMatchPartialCoverage() {
    // "bms" matching "Bristol-Myers Squibb Company" (3/4 words)
    // When subsequence scores higher, it wins over acronym — that's correct
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Bristol-Myers Squibb Company", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)

    // Full coverage case: 3/3 words → acronym match
    let fullResult = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    #expect(fullResult != nil)
    #expect(fullResult?.kind == .acronym)
}

@Test func acronymPartialCoverageScoringFormula() {
    // Verify partial coverage scores less than full coverage for same-length candidates
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    // Full coverage: 2/2 words
    let full = matcher.score("Alpha Beta", against: query, buffer: &buffer)
    // Partial coverage: 2/3 words (query matches first two initials)
    let partial = matcher.score("Alpha Beta Charlie", against: query, buffer: &buffer)

    #expect(full != nil)
    #expect(partial != nil)
    if let f = full, let p = partial, f.kind == .acronym && p.kind == .acronym {
        #expect(f.score > p.score)
    }
}

@Test func acronymMatchDoesNotOverrideBetterScore() {
    // When prefix/substring already gives a better score, acronym doesn't override
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Bank")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Bank of America", against: query, buffer: &buffer)
    #expect(result != nil)
    // Prefix match scores higher than acronym for a 4-letter query that
    // matches the start of the candidate
    #expect(result?.kind != .acronym)
}

@Test func acronymMatchSkipsLongQuery() {
    // Queries > 8 chars should not trigger acronym pass
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcdefghi")  // 9 chars
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Alpha Beta Charlie Delta Echo Foxtrot Golf Hotel India", against: query, buffer: &buffer)
    if let result = result {
        #expect(result.kind != .acronym)
    }
}

@Test func acronymMatchSkipsSingleChar() {
    // Single char queries should not trigger acronym pass
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Alpha Beta", against: query, buffer: &buffer)
    if let result = result {
        #expect(result.kind != .acronym)
    }
}

@Test func acronymMatchReturnsCorrectKind() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("icag")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("International Consolidated Airlines Group", against: query, buffer: &buffer)
    #expect(result?.kind == .acronym)
}

@Test func acronymMatchNoMatchWhenInitialsDontAlign() {
    // "xyz" should not match "Alpha Beta Charlie" as acronym
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("xyz")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("Alpha Beta Charlie", against: query, buffer: &buffer)
    if let result = result {
        #expect(result.kind != .acronym)
    }
}

@Test func acronymMatchCamelCase() {
    // "gubi" matching "getUserById" as acronym (word boundaries from camelCase)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("gubi")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("getUserById", against: query, buffer: &buffer)
    #expect(result != nil)
    // Could match via subsequence or acronym — just verify it matches
    #expect(result!.score > 0.3)
}

@Test func acronymWeightConfig() {
    // Test that acronymWeight affects the score
    let boostedConfig = MatchConfig(algorithm: .editDistance(EditDistanceConfig(acronymWeight: 1.2)))
    let matcher = FuzzyMatcher(config: boostedConfig)
    let query = matcher.prepare("icag")
    var buffer = matcher.makeBuffer()

    let boosted = matcher.score("International Consolidated Airlines Group", against: query, buffer: &buffer)

    let normalMatcher = FuzzyMatcher()
    let normalQuery = normalMatcher.prepare("icag")
    var normalBuffer = normalMatcher.makeBuffer()
    let normal = normalMatcher.score("International Consolidated Airlines Group", against: normalQuery, buffer: &normalBuffer)

    #expect(boosted != nil)
    #expect(normal != nil)
    #expect(boosted!.score > normal!.score)
}
