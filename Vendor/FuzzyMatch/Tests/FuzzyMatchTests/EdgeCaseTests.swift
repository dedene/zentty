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

// MARK: - Single Character Strings

@Test func singleCharacterExactMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("a", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func singleCharacterPrefixMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
}

@Test func singleCharacterNoMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("x")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    // Single character 'x' not in "abc" - may or may not match depending on edit distance
    // With default maxEditDistance of 2, a single character query can match
    // But the score might be below minScore
    // This is implementation-dependent
    if let score = result?.score {
        #expect(score >= 0.0)
    }
}

// MARK: - Very Short Queries (1-2 chars)

@Test func twoCharacterExactMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("ab", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func twoCharacterPrefixMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    #expect(result != nil)
}

@Test func twoCharacterSubstringMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    #expect(result != nil)
}

@Test func shortQueryNoTrigrams() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")

    // Short queries should have no trigrams
    #expect(query.trigrams.isEmpty)
}

// MARK: - Query Longer Than Candidate

@Test func queryLongerThanCandidateNoMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcdefghij")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    // Query is much longer than candidate, should likely not match
    // due to length bounds filter (candidate must be >= queryLength - maxEditDistance)
    #expect(result == nil)
}

@Test func querySlightlyLongerThanCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcd")
    var buffer = matcher.makeBuffer()

    // With maxEditDistance 2, candidate can be queryLength - 2 = 2 chars minimum
    _ = matcher.score("ab", against: query, buffer: &buffer)
    // Result depends on edit distance and prefilters; test validates no crash
}

// MARK: - Identical Strings

@Test func identicalStringsExactMatch() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let testStrings = [
        "hello",
        "test",
        "FuzzyMatcher",
        "a",
        "ab",
        "abc",
        "1234567890",
        "hello_world_123"
    ]

    for str in testStrings {
        let query = matcher.prepare(str)
        let result = matcher.score(str, against: query, buffer: &buffer)

        #expect(result?.score == 1.0, "Expected exact match for '\(str)'")
        #expect(result?.kind == .exact, "Expected .exact match kind for '\(str)'")
    }
}

// MARK: - Completely Different Strings

@Test func completelyDifferentStringsNoMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("xyz", against: query, buffer: &buffer)

    // Completely different strings with no common characters
    // Should not match (below minScore or rejected by prefilters)
    #expect(result == nil)
}

@Test func differentLengthDifferentContent() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcdef")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("xyz", against: query, buffer: &buffer)

    #expect(result == nil)
}

// MARK: - Unicode Characters

@Test func unicodeCharactersBasicASCII() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func unicodeMultibyteCharacters() {
    // Multi-byte UTF-8 characters (non-ASCII)
    // The library operates on UTF-8 bytes, so multi-byte characters
    // are treated as sequences of bytes
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Same string should match exactly
    let query = matcher.prepare("caf")
    let result = matcher.score("caf", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func unicodeInLongerString() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("test123", against: query, buffer: &buffer)

    #expect(result != nil)
}

// MARK: - Empty Strings

@Test func emptyQueryEmptyCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func emptyQueryNonEmptyCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func nonEmptyQueryEmptyCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("", against: query, buffer: &buffer)

    #expect(result == nil)
}

// MARK: - Whitespace

@Test func whitespaceInStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello world")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello world", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func leadingTrailingWhitespace() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare(" hello ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score(" hello ", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func tabsAndNewlines() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello\tworld")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello\tworld", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

// MARK: - Special Characters

@Test func underscoresInStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello_world")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello_world", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func numbersInStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test123")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("test123", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func mixedSpecialCharacters() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a_1_b_2")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("a_1_b_2", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

// MARK: - Repeated Characters

@Test func repeatedCharactersExactMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("aaaaaa")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("aaaaaa", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func repeatedCharactersDifferentLength() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("aaa")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("aaaaaaa", against: query, buffer: &buffer)

    #expect(result != nil)
}

// MARK: - Very Long Strings

@Test func longStringsExactMatch() {
    let matcher = FuzzyMatcher()
    let longString = String(repeating: "abcdefghij", count: 10) // 100 chars
    let query = matcher.prepare(longString)
    var buffer = matcher.makeBuffer()

    let result = matcher.score(longString, against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func longQueryShortCandidate() {
    let matcher = FuzzyMatcher()
    let longString = String(repeating: "abcdefghij", count: 10) // 100 chars
    let query = matcher.prepare(longString)
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    // Should fail length bounds
    #expect(result == nil)
}

@Test func shortQueryLongCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    // Candidate can be up to 3x query length = 9 chars
    let result = matcher.score("abcdefghi", against: query, buffer: &buffer)

    #expect(result != nil)
}

// MARK: - Boundary Length Tests

@Test func candidateAtMaxAllowedLength() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc") // length 3
    var buffer = matcher.makeBuffer()

    // Max candidate length is queryLength * 3 = 9
    let result = matcher.score("abcdefghi", against: query, buffer: &buffer)

    #expect(result != nil)
}

@Test func candidateExceedsMaxAllowedLength() {
    // This test verifies that long candidates CAN match (for subsequence matching)
    // There is no upper length restriction to support abbreviation-style matching
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc") // length 3
    var buffer = matcher.makeBuffer()

    // Long candidate should still match since "abc" is a prefix
    let result = matcher.score("abcdefghij", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .prefix)
}

@Test func candidateAtMinAllowedLength() {
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    let query = matcher.prepare("abcde") // length 5
    var buffer = matcher.makeBuffer()

    // Min candidate length is queryLength - maxEditDistance = 3
    _ = matcher.score("abc", against: query, buffer: &buffer)
    // Result depends on edit distance and prefilters; test validates no crash
}
