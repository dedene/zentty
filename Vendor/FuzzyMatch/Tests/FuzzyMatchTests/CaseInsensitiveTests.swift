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

// MARK: - Basic Case Insensitivity

@Test func matchingIgnoresCaseUpperToLower() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ABC")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abc", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func matchingIgnoresCaseLowerToUpper() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("ABC", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

// MARK: - Mixed Case Strings

@Test func mixedCaseQueryMatchesMixedCaseCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("HeLLo")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hElLO", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func mixedCaseInLongerStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("FuzzyMatcher")
    var buffer = matcher.makeBuffer()

    let result1 = matcher.score("fuzzymatcher", against: query, buffer: &buffer)
    let result2 = matcher.score("FUZZYMATCHER", against: query, buffer: &buffer)
    let result3 = matcher.score("FuZzYmAtChEr", against: query, buffer: &buffer)

    #expect(result1?.score == 1.0)
    #expect(result2?.score == 1.0)
    #expect(result3?.score == 1.0)
}

@Test func camelCaseMatching() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("camelcase")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("CamelCase", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func pascalCaseMatching() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("PASCALCASE")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("PascalCase", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func snakeCaseWithCases() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("snake_case")
    var buffer = matcher.makeBuffer()

    let result1 = matcher.score("SNAKE_CASE", against: query, buffer: &buffer)
    let result2 = matcher.score("Snake_Case", against: query, buffer: &buffer)

    #expect(result1?.score == 1.0)
    #expect(result2?.score == 1.0)
}

// MARK: - Non-ASCII Characters Pass Through

@Test func nonASCIICharactersPassThroughUnchanged() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // UTF-8 encoded non-ASCII characters should pass through unchanged
    let query = matcher.prepare("cafe")
    let result = matcher.score("cafe", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func nonASCIIInQuery() {
    // Non-ASCII bytes pass through lowercaseASCII unchanged
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Test with a string containing non-ASCII
    let query = matcher.prepare("test123")
    let result = matcher.score("TEST123", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func numbersAreNotAffectedByCase() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test123")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("TEST123", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func specialCharactersNotAffectedByCase() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello_world")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("HELLO_WORLD", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

// MARK: - Prefix and Substring Case Insensitivity

@Test func prefixMatchCaseInsensitive() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("TEST")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("testing", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .prefix)
}

@Test func substringMatchCaseInsensitive() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("TEST")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("unittest", against: query, buffer: &buffer)

    #expect(result != nil)
}

// MARK: - Case Preservation in Original

@Test func queryOriginalPreservesCase() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("HeLLo WoRLd")

    #expect(query.original == "HeLLo WoRLd")
}

// MARK: - Scoring Consistency Across Cases

@Test func scoringConsistentAcrossCases() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query1 = matcher.prepare("hello")
    let query2 = matcher.prepare("HELLO")
    let query3 = matcher.prepare("HeLLo")

    let score1 = matcher.score("helloworld", against: query1, buffer: &buffer)?.score
    let score2 = matcher.score("helloworld", against: query2, buffer: &buffer)?.score
    let score3 = matcher.score("helloworld", against: query3, buffer: &buffer)?.score

    #expect(score1 == score2)
    #expect(score2 == score3)
}

@Test func candidateCaseDoesNotAffectScore() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let score1 = matcher.score("helloworld", against: query, buffer: &buffer)?.score
    let score2 = matcher.score("HELLOWORLD", against: query, buffer: &buffer)?.score
    let score3 = matcher.score("HelloWorld", against: query, buffer: &buffer)?.score

    #expect(score1 == score2)
    #expect(score2 == score3)
}

// MARK: - Edge Cases with Case

@Test func singleCharacterCaseInsensitive() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("A")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("a", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func allUppercaseQuery() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("abcdefghijklmnopqrstuvwxyz", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}

@Test func allLowercaseQuery() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcdefghijklmnopqrstuvwxyz")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("ABCDEFGHIJKLMNOPQRSTUVWXYZ", against: query, buffer: &buffer)

    #expect(result?.score == 1.0)
}
