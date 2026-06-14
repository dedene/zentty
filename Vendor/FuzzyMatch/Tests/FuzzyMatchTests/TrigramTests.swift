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

// MARK: - Trigram Computation

@Test func trigramComputationBasic() {
    let bytes: [UInt8] = Array("abcd".utf8)
    let trigrams = computeTrigrams(bytes)

    // "abc", "bcd" = 2 trigrams
    #expect(trigrams.count == 2)
}

@Test func trigramComputationMinimumLength() {
    let bytes: [UInt8] = Array("abc".utf8)
    let trigrams = computeTrigrams(bytes)

    // Exactly 3 characters = 1 trigram
    #expect(trigrams.count == 1)
}

@Test func trigramComputationTooShort() {
    let bytes1: [UInt8] = Array("ab".utf8)
    let bytes2: [UInt8] = Array("a".utf8)
    let bytes3: [UInt8] = []

    #expect(computeTrigrams(bytes1).isEmpty)
    #expect(computeTrigrams(bytes2).isEmpty)
    #expect(computeTrigrams(bytes3).isEmpty)
}

@Test func trigramComputationLongerString() {
    let bytes: [UInt8] = Array("hello".utf8)
    let trigrams = computeTrigrams(bytes)

    // "hel", "ell", "llo" = 3 trigrams
    #expect(trigrams.count == 3)
}

@Test func trigramComputationRepeatedCharacters() {
    let bytes: [UInt8] = Array("aaaa".utf8)
    let trigrams = computeTrigrams(bytes)

    // "aaa", "aaa" = only 1 unique trigram
    #expect(trigrams.count == 1)
}

@Test func trigramComputationAllUnique() {
    let bytes: [UInt8] = Array("abcdef".utf8)
    let trigrams = computeTrigrams(bytes)

    // "abc", "bcd", "cde", "def" = 4 unique trigrams
    #expect(trigrams.count == 4)
}

// MARK: - Trigram Hash

@Test func trigramHashBasic() {
    let hash = trigramHash(0x61, 0x62, 0x63) // "abc"

    // Should combine bytes: a | (b << 8) | (c << 16)
    let expected: UInt32 = 0x61 | (0x62 << 8) | (0x63 << 16)
    #expect(hash == expected)
}

@Test func trigramHashUniqueness() {
    // Different trigrams should produce different hashes
    let hash1 = trigramHash(0x61, 0x62, 0x63) // "abc"
    let hash2 = trigramHash(0x62, 0x63, 0x64) // "bcd"
    let hash3 = trigramHash(0x61, 0x63, 0x62) // "acb"

    #expect(hash1 != hash2)
    #expect(hash1 != hash3)
    #expect(hash2 != hash3)
}

@Test func trigramHashOrderMatters() {
    let hash1 = trigramHash(0x61, 0x62, 0x63) // "abc"
    let hash2 = trigramHash(0x63, 0x62, 0x61) // "cba"

    #expect(hash1 != hash2)
}

@Test func trigramHashSameInputSameOutput() {
    let hash1 = trigramHash(0x68, 0x65, 0x6C) // "hel"
    let hash2 = trigramHash(0x68, 0x65, 0x6C) // "hel"

    #expect(hash1 == hash2)
}

@Test func trigramHashBoundaryValues() {
    // Test with max byte values
    let hash = trigramHash(0xFF, 0xFF, 0xFF)
    let expected: UInt32 = 0xFF | (0xFF << 8) | (0xFF << 16)
    #expect(hash == expected)
}

@Test func trigramHashZeroBytes() {
    let hash = trigramHash(0x00, 0x00, 0x00)
    #expect(hash == 0)
}

// MARK: - Count Shared Trigrams

@Test func countSharedTrigramsExactMatch() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("hello".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    #expect(count == 3) // "hel", "ell", "llo"
}

@Test func countSharedTrigramsPartialMatch() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("help".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    // "hel" is shared, "elp" is not in query trigrams
    #expect(count == 1)
}

@Test func countSharedTrigramsNoMatch() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("xyz".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    #expect(count == 0)
}

@Test func countSharedTrigramsCandidateTooShort() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("he".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    #expect(count == 0)
}

@Test func countSharedTrigramsEmptyQueryTrigrams() {
    let queryTrigrams = Set<UInt32>()

    let candidateBytes: [UInt8] = Array("hello".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    #expect(count == 0)
}

@Test func countSharedTrigramsSubstring() {
    let queryBytes: [UInt8] = Array("test".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("unittest".utf8)
    let count = countSharedTrigrams(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams
    )

    // "tes", "est" should be found in "unittest"
    #expect(count >= 2)
}

// MARK: - Trigram Filter

@Test func trigramFilterPassesExactMatch() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("hello".utf8)
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 2
    )

    #expect(passes)
}

@Test func trigramFilterPassesSimilarStrings() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("hallo".utf8)
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 2
    )

    // "hel" -> "hal" (1 different), "ell" -> "all" (different), "llo" shared
    // At least 1 shared trigram, and within edit distance allowance
    #expect(passes)
}

@Test func trigramFilterRejectsDissimilarStrings() {
    // With the relaxed trigram threshold (3 * maxEditDistance factor for DL transpositions),
    // very short candidates pass the trigram filter but are rejected by edit distance later.
    // Use a longer candidate that is clearly dissimilar to test rejection.
    let queryBytes: [UInt8] = Array("configuration".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("xyz".utf8)
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 2
    )

    // queryTrigrams.count = 11, threshold = 11 - 6 = 5, xyz has 1 trigram, 0 shared → rejects
    #expect(!passes)
}

@Test func trigramFilterNoFalseNegatives() {
    // Test that strings within edit distance are not rejected
    let matcher = FuzzyMatcher(config: MatchConfig(algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 2))))
    var buffer = matcher.makeBuffer()

    // Test pairs that should match
    let testCases: [(String, String)] = [
        ("hello", "hallo"), // 1 substitution
        ("hello", "helllo"), // 1 insertion
        ("testing", "testng"), // 1 deletion
        ("test", "tset") // 1 transposition
    ]

    for (query, candidate) in testCases {
        let preparedQuery = matcher.prepare(query)
        let result = matcher.score(candidate, against: preparedQuery, buffer: &buffer)
        // Strings within edit distance must not be rejected by trigram filter
        #expect(result != nil, "'\(query)' should match '\(candidate)' — trigram filter must not cause false negative")
    }
}

@Test func trigramFilterPassesEmptyQueryTrigrams() {
    let queryTrigrams = Set<UInt32>()

    let candidateBytes: [UInt8] = Array("anything".utf8)
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 2
    )

    // Empty query trigrams should always pass
    #expect(passes)
}

@Test func trigramFilterWithHigherEditDistance() {
    let queryBytes: [UInt8] = Array("hello".utf8)
    let queryTrigrams = computeTrigrams(queryBytes)

    let candidateBytes: [UInt8] = Array("world".utf8)
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 5
    )

    // With high edit distance, more dissimilar strings may pass
    // "hello" has 3 trigrams, candidate needs at least -2 (3-5=negative, so any count passes)
    #expect(passes)
}

@Test func trigramFilterBoundaryCase() {
    // Query with 3 trigrams, candidate must have at least 1 (3-2=1) shared
    let queryBytes: [UInt8] = Array("hello".utf8) // 3 trigrams
    let queryTrigrams = computeTrigrams(queryBytes)

    // Candidate that shares exactly 1 trigram
    let candidateBytes: [UInt8] = Array("llox".utf8) // "llo" is shared
    let passes = passesTrigramFilter(
        candidateBytes: candidateBytes,
        queryTrigrams: queryTrigrams,
        maxEditDistance: 2
    )

    #expect(passes)
}

// MARK: - Trigram Integration with FuzzyMatcher

@Test func trigramIntegrationLongQuery() {
    // Queries of 4+ characters use trigram filtering
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("testing")
    var buffer = matcher.makeBuffer()

    // Should match with trigram filtering active
    let result = matcher.score("testing", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func trigramIntegrationShortQuery() {
    // Queries < 4 characters skip trigram filtering
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()

    // Should still work without trigram filtering
    let result = matcher.score("abc", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}
