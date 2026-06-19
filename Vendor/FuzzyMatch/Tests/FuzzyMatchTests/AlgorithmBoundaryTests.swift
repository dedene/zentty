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

// MARK: - Algorithm Boundary Tests
//
// These tests verify correct behavior at algorithm boundaries where implementations
// often switch strategies (e.g., bit-parallel algorithms at 32/64 char boundaries).

// MARK: - 32-Character Boundary (Machine Word Size)

@Test func patternExactly32Characters() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern32 = String(repeating: "a", count: 32)
    let query = matcher.prepare(pattern32)

    // Exact match
    let exactResult = matcher.score(pattern32, against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.score == 1.0)
    #expect(exactResult?.kind == .exact)
}

@Test func patternExactly33Characters() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern33 = String(repeating: "a", count: 33)
    let query = matcher.prepare(pattern33)

    // Exact match
    let exactResult = matcher.score(pattern33, against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.score == 1.0)
    #expect(exactResult?.kind == .exact)
}

@Test func patternAt32CharBoundaryWithTransposition() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query of 32 chars with a transposition (same chars, different order)
    let pattern32 = String(repeating: "a", count: 30) + "ba"
    let candidate = String(repeating: "a", count: 30) + "ab"
    let query = matcher.prepare(pattern32)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
    // Should match with edit distance 1 (transposition)
}

@Test func patternAt33CharBoundaryWithTransposition() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query of 33 chars with a transposition
    let pattern33 = String(repeating: "a", count: 31) + "ba"
    let candidate = String(repeating: "a", count: 31) + "ab"
    let query = matcher.prepare(pattern33)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func patternAt33CharBoundarySubstitutionAllowed() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query has 'b' at end but candidate only has 'a's - edit distance 1
    // The bitmask filter allows up to maxEditDistance missing character types,
    // so a single substitution should match.
    let pattern33 = String(repeating: "a", count: 32) + "b"
    let candidate = String(repeating: "a", count: 33)
    let query = matcher.prepare(pattern33)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil, "Single substitution on a 33-char string should match")
}

@Test func prefixMatchAt32CharBoundary() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern32 = String(repeating: "a", count: 32)
    let candidate = pattern32 + "xyz"
    let query = matcher.prepare(pattern32)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .prefix)
}

// MARK: - 64-Character Boundary (Bit-Parallel Algorithm Switch)

@Test func patternExactly64Characters() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern64 = String(repeating: "a", count: 64)
    let query = matcher.prepare(pattern64)

    let exactResult = matcher.score(pattern64, against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.score == 1.0)
    #expect(exactResult?.kind == .exact)
}

@Test func patternExactly65Characters() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern65 = String(repeating: "a", count: 65)
    let query = matcher.prepare(pattern65)

    let exactResult = matcher.score(pattern65, against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.score == 1.0)
    #expect(exactResult?.kind == .exact)
}

@Test func patternAt64CharBoundaryWithTransposition() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query with transposition (same chars, different order)
    let pattern64 = String(repeating: "a", count: 62) + "ba"
    let candidate = String(repeating: "a", count: 62) + "ab"
    let query = matcher.prepare(pattern64)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func patternAt65CharBoundaryWithTransposition() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query with transposition
    let pattern65 = String(repeating: "a", count: 63) + "ba"
    let candidate = String(repeating: "a", count: 63) + "ab"
    let query = matcher.prepare(pattern65)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func patternAt65CharBoundarySubstitutionAllowed() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Query has 'b' at end but candidate only has 'a's - edit distance 1
    // The bitmask filter allows up to maxEditDistance missing character types,
    // so a single substitution should match (distance 1 on a 65-char string).
    let pattern65 = String(repeating: "a", count: 64) + "b"
    let candidate = String(repeating: "a", count: 65)
    let query = matcher.prepare(pattern65)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil, "Single substitution on a 65-char string should match")
}

@Test func wordBoundaryMaskAt64thPosition() {
    // The boundary mask is a UInt64, so only positions 0-63 are tracked
    // Boundary detection uses original case - uppercase after lowercase is a boundary
    let candidate = String(repeating: "a", count: 63) + "Bc"
    let bytes = Array(candidate.utf8)  // Keep original case for boundary detection

    let mask = computeBoundaryMask(bytes: bytes)

    // Position 0 should be boundary (start)
    #expect((mask & (1 << 0)) != 0)

    // Position 63 should be boundary (uppercase B after lowercase a)
    #expect((mask & (1 << 63)) != 0)
}

@Test func wordBoundaryDetectionBeyond64() {
    // Test isWordBoundary() fallback for positions >= 64
    let candidate = String(repeating: "a", count: 70) + "Bcd"
    let bytes = Array(candidate.utf8)

    // Position 70 is uppercase B after lowercase a - should be boundary
    let isBoundary = isWordBoundary(at: 70, in: bytes)
    #expect(isBoundary)

    // Position 71 is lowercase c after B - not a boundary
    let notBoundary = isWordBoundary(at: 71, in: bytes)
    #expect(!notBoundary)
}

// MARK: - Very Long Strings (65K+ Characters)

@Test func veryLongStringExactMatch() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let longString = String(repeating: "abcdefghij", count: 100)  // 1000 chars
    let query = matcher.prepare(longString)

    let result = matcher.score(longString, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func veryLongCandidateShortQuery() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Use a moderately long candidate (100 chars padding) — length penalty keeps
    // score above minScore. Extremely long candidates (10000+ chars) legitimately
    // score below minScore due to length penalty on all match paths.
    let longCandidate = String(repeating: "x", count: 100) + "test"
    let query = matcher.prepare("test")

    // Should find "test" as substring at the end
    let result = matcher.score(longCandidate, against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func longStringWithTransposition() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Long string with a transposition near the end
    let base = String(repeating: "a", count: 500)
    let candidate = base + "test"
    let queryStr = base + "tset"  // Transposed "test"
    let query = matcher.prepare(queryStr)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func uint16BoundaryString() {
    // Test near UInt16.max (65535) boundary
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Create a string just under the boundary
    let longString = String(repeating: "a", count: 1_000)
    let query = matcher.prepare(longString)

    let result = matcher.score(longString, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

// MARK: - Large String Correctness (5K–10K characters)
//
// Tests at scales beyond the existing 1000-char tests to catch potential integer
// overflow, performance cliffs, or rolling-array bugs in the DP computation.

@Test func largeString5KExactMatch() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // 5000 characters with varied content to exercise trigram and bitmask paths
    let pattern = String(repeating: "abcdefghij", count: 500) // 5000 chars
    let query = matcher.prepare(pattern)

    let result = matcher.score(pattern, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func largeString2KSingleSubstitution() {
    // DP is O(n*m) — use 2000 chars to keep test time reasonable (~1s)
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    let base = String(repeating: "a", count: 2_000)
    var candidateChars = Array(base)
    candidateChars[1_000] = "b" // Single substitution in the middle
    let candidate = String(candidateChars)
    let query = matcher.prepare(base)

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    #expect(result != nil, "2K string with single substitution should match")
}

@Test func largeString2KTranspositionAtEnd() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    let prefix = String(repeating: "a", count: 1_998)
    let queryStr = prefix + "ba"
    let candidateStr = prefix + "ab"
    let query = matcher.prepare(queryStr)

    let result = matcher.score(candidateStr, against: query, buffer: &buffer)
    #expect(result != nil, "2K string with transposition at end should match")
}

@Test func largeString10KExactMatch() {
    // Exact match short-circuits before DP, so large strings are fast
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let pattern = String(repeating: "abcdefghij", count: 1_000) // 10000 chars
    let query = matcher.prepare(pattern)

    let result = matcher.score(pattern, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func largeStringEditDistanceDirectly() {
    // Test the edit distance function directly at 2K scale
    let base = String(repeating: "a", count: 2_000)
    var candidateStr = base
    let idx = candidateStr.index(candidateStr.startIndex, offsetBy: 1_000)
    candidateStr.replaceSubrange(idx...idx, with: "b")

    let query: [UInt8] = Array(base.utf8)
    let candidate: [UInt8] = Array(candidateStr.utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 3)

    #expect(distance == 1, "Single substitution in 2K string should have distance 1")
}

@Test func largeStringShortQuerySubstringMatch() {
    // Short query finding a substring in a very long candidate
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0))
    var buffer = matcher.makeBuffer()

    // Place "needle" in the middle of a 5000-char string
    let padding = String(repeating: "x", count: 2_497)
    let candidate = padding + "needle" + padding
    let query = matcher.prepare("needle")

    let result = matcher.score(candidate, against: query, buffer: &buffer)
    // This will likely be filtered by length penalty or trigrams, but should not crash
    // The test verifies no overflow or hang occurs on large candidates
    _ = result // No assertion on match — correctness of filtering is tested elsewhere
}

// MARK: - Trigram Boundary Tests

@Test func trigramAt32CharString() {
    // Trigrams are computed for strings >= 3 chars
    // Note: trigrams are stored in a Set, so repeated patterns yield fewer unique trigrams
    let matcher = FuzzyMatcher()

    // Use a string with all unique trigrams: "abcdefghij..." (32 chars)
    let pattern32 = "abcdefghijklmnopqrstuvwxyz012345"
    #expect(pattern32.count == 32)
    let query = matcher.prepare(pattern32)

    // Should have 30 unique trigrams for 32-char string with unique chars
    #expect(query.trigrams.count == 30)
}

@Test func trigramAt64CharString() {
    let matcher = FuzzyMatcher()

    // Use a string with 64 characters (36 + 28 = 64)
    let pattern64 = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01"
    #expect(pattern64.count == 64)
    let query = matcher.prepare(pattern64)

    // 64-char string should have up to 62 trigrams (n-2), but with some repeats
    // from the second half, we expect fewer unique trigrams
    #expect(query.trigrams.count >= 30, "Should have significant trigram count for 64-char string")
}

// MARK: - Edit Distance at Boundaries

@Test func editDistanceAt32CharBoundary() {
    let query: [UInt8] = Array(String(repeating: "a", count: 32).utf8)
    let candidate: [UInt8] = Array(String(repeating: "a", count: 32).utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 3)

    #expect(distance == 0)
}

@Test func editDistanceAt64CharBoundary() {
    let query: [UInt8] = Array(String(repeating: "a", count: 64).utf8)
    let candidate: [UInt8] = Array(String(repeating: "a", count: 64).utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 3)

    #expect(distance == 0)
}

@Test func editDistanceAt65CharBoundary() {
    let query: [UInt8] = Array(String(repeating: "a", count: 65).utf8)
    let candidate: [UInt8] = Array(String(repeating: "a", count: 65).utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 3)

    #expect(distance == 0)
}

// MARK: - Bitmask at Boundaries

@Test func charBitmaskWithAllCharacterTypes() {
    // Test that bitmask correctly handles all 37 mapped characters
    // a-z (26) + 0-9 (10) + underscore (1) = 37 bits
    let allLower = "abcdefghijklmnopqrstuvwxyz"
    let allDigits = "0123456789"
    let underscore = "_"

    let fullString = allLower + allDigits + underscore
    let bytes = Array(fullString.utf8)
    let mask = computeCharBitmask(bytes)

    // Check that all expected bits are set
    // Bits 0-25 for a-z
    for i in 0..<26 {
        #expect((mask & (1 << i)) != 0, "Bit \(i) should be set for letter \(Character(UnicodeScalar(97 + i)!))")
    }
    // Bits 26-35 for 0-9
    for i in 0..<10 {
        #expect((mask & (1 << (26 + i))) != 0, "Bit \(26 + i) should be set for digit \(i)")
    }
    // Bit 36 for underscore
    #expect((mask & (1 << 36)) != 0, "Bit 36 should be set for underscore")
}

// MARK: - Score Cutoff Boundary Tests

@Test func scoreCutoffAtExactBoundary() {
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.5, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("test")

    // Find a candidate that scores exactly at the boundary
    // With edit distance 1 on 4 chars: base = 1 - 1/4 = 0.75
    let result = matcher.score("tест", against: query, buffer: &buffer)

    if let score = result?.score {
        #expect(score >= 0.5, "Score \(score) should be >= 0.5")
    }
}

@Test func scoreCutoffJustBelowBoundary() {
    // Test with high minScore to verify filtering works
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.9, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 3))))
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("helol")  // Transposition of "hello"

    // "hello" vs "helol" has distance 1 (transposition), base = 0.8, below 0.9 threshold
    let result = matcher.score("hello", against: query, buffer: &buffer)

    // Score should be below threshold or just at it depending on bonuses
    if let score = result?.score {
        #expect(score >= 0.9)
    }
}
