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

// MARK: - Main API Tests

@Test func prepareCreatesCorrectFuzzyQuery() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Hello")

    #expect(query.original == "Hello")
    #expect(query.lowercased == [0x68, 0x65, 0x6c, 0x6c, 0x6f]) // "hello" in UTF-8
    #expect(query.charBitmask != 0)
    #expect(query.trigrams.count == 3) // "hel", "ell", "llo"
}

@Test func prepareStoresOriginalString() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("TestQuery")

    #expect(query.original == "TestQuery")
}

@Test func prepareLowercasesBytes() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ABC")

    #expect(query.lowercased == [0x61, 0x62, 0x63]) // "abc"
}

@Test func prepareComputesCharBitmask() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")

    // 'a' is bit 0, 'b' is bit 1
    #expect(query.charBitmask == 0b11)
}

@Test func prepareComputesTrigramsForLongStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abcd")

    // "abc", "bcd" = 2 trigrams
    #expect(query.trigrams.count == 2)
}

@Test func prepareSkipsTrigramsForShortStrings() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ab")

    #expect(query.trigrams.isEmpty)
}

@Test func scoreReturnsCorrectResultsForVariousInputs() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    // Exact match
    let exactResult = matcher.score("test", against: query, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult?.kind == .exact)

    // Prefix match
    let prefixResult = matcher.score("testing", against: query, buffer: &buffer)
    #expect(prefixResult != nil)

    // Substring match
    let substringResult = matcher.score("unittest", against: query, buffer: &buffer)
    #expect(substringResult != nil)
}

@Test func exactMatchReturnsScoreOneAndExactKind() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("hello", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func prefixMatchWorksCorrectly() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("testing", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result?.kind == .prefix)
    #expect(result!.score > 0.0)
}

@Test func substringMatchWorksCorrectly() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("unittest", against: query, buffer: &buffer)

    #expect(result != nil)
    #expect(result!.score > 0.0)
}

@Test func bufferReuseProducesCorrectResults() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query1 = matcher.prepare("hello")
    let query2 = matcher.prepare("world")

    // Use same buffer for multiple queries
    let result1 = matcher.score("hello", against: query1, buffer: &buffer)
    let result2 = matcher.score("world", against: query2, buffer: &buffer)
    let result3 = matcher.score("hello", against: query1, buffer: &buffer)

    #expect(result1?.score == 1.0)
    #expect(result2?.score == 1.0)
    #expect(result3?.score == 1.0)
}

@Test func bufferReuseWithDifferentSizes() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let shortQuery = matcher.prepare("a")
    let longQuery = matcher.prepare("thisisaverylongquery")

    let result1 = matcher.score("abc", against: shortQuery, buffer: &buffer)
    let result2 = matcher.score("thisisaverylongquery", against: longQuery, buffer: &buffer)
    let result3 = matcher.score("a", against: shortQuery, buffer: &buffer)

    #expect(result1 != nil)
    #expect(result2?.score == 1.0)
    #expect(result3?.score == 1.0)
}

// MARK: - Scoring Tests

@Test func scoreHigherForBetterMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()

    let exactScore = matcher.score("test", against: query, buffer: &buffer)?.score ?? 0
    let prefixScore = matcher.score("testing", against: query, buffer: &buffer)?.score ?? 0

    // Exact match should have score >= prefix match
    // Note: With high prefixWeight, prefix matches can also reach 1.0
    #expect(exactScore >= prefixScore)
}

@Test func scoreBetweenZeroAndOne() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello")
    var buffer = matcher.makeBuffer()

    let candidates = ["hello", "helloworld", "hell", "helo", "help", "hallo"]

    for candidate in candidates {
        if let result = matcher.score(candidate, against: query, buffer: &buffer) {
            #expect(result.score >= 0.0)
            #expect(result.score <= 1.0)
        }
    }
}
