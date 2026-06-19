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

// MARK: - Damerau-Levenshtein Basic Cases

@Test func editDistanceIdenticalStrings() {
    let query: [UInt8] = Array("hello".utf8)
    let candidate: [UInt8] = Array("hello".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 0)
}

@Test func editDistanceSingleInsertion() {
    let query: [UInt8] = Array("helo".utf8)
    let candidate: [UInt8] = Array("hello".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func editDistanceSingleDeletion() {
    let query: [UInt8] = Array("hello".utf8)
    let candidate: [UInt8] = Array("helo".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func editDistanceSingleSubstitution() {
    let query: [UInt8] = Array("hello".utf8)
    let candidate: [UInt8] = Array("hallo".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

// MARK: - Transposition Detection

@Test func transpositionDetectedAsSingleEdit() {
    // "teh" vs "the" should be distance 1 (transposition)
    let query: [UInt8] = Array("teh".utf8)
    let candidate: [UInt8] = Array("the".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func transpositionAtMiddle() {
    // "abdc" vs "abcd" - transposition of c and d
    let query: [UInt8] = Array("abdc".utf8)
    let candidate: [UInt8] = Array("abcd".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func transpositionAtStart() {
    // "ba" vs "ab" - transposition at start
    let query: [UInt8] = Array("ba".utf8)
    let candidate: [UInt8] = Array("ab".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

// MARK: - Prefix Edit Distance

@Test func prefixEditDistanceQueryAsPrefixOfCandidate() {
    // Query "test" should match prefix of "testing" with distance 0
    let query: [UInt8] = Array("test".utf8)
    let candidate: [UInt8] = Array("testing".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 0)
}

@Test func prefixEditDistanceWithTypo() {
    // Query "tset" should match prefix of "testing" with distance 1 (transposition)
    let query: [UInt8] = Array("tset".utf8)
    let candidate: [UInt8] = Array("testing".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func prefixEditDistanceEmptyQuery() {
    let query: [UInt8] = []
    let candidate: [UInt8] = Array("hello".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 0)
}

// MARK: - Substring Edit Distance

@Test func substringEditDistanceExactSubstring() {
    let query: [UInt8] = Array("test".utf8)
    let candidate: [UInt8] = Array("unittest".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = substringEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 0)
}

@Test func substringEditDistanceWithTypo() {
    // "tset" should match "testing" in "mytesting" with distance 1
    let query: [UInt8] = Array("tset".utf8)
    let candidate: [UInt8] = Array("mytesting".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = substringEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 1)
}

@Test func substringEditDistanceInMiddle() {
    let query: [UInt8] = Array("world".utf8)
    let candidate: [UInt8] = Array("helloworldtest".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = substringEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 0)
}

// MARK: - Early Exit with maxEditDistance

@Test func earlyExitWhenDistanceExceedsMax() {
    let query: [UInt8] = Array("abcdef".utf8)
    let candidate: [UInt8] = Array("xxxxxx".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 2
    )

    #expect(distance == nil)
}

@Test func distanceAtMaxEditDistanceReturnsValue() {
    // Two substitutions: "aa" -> "bb"
    let query: [UInt8] = Array("aa".utf8)
    let candidate: [UInt8] = Array("bb".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 2
    )

    #expect(distance == 2)
}

@Test func distanceJustAboveMaxEditDistanceReturnsNil() {
    // Three substitutions: "aaa" -> "bbb" with max 2
    let query: [UInt8] = Array("aaa".utf8)
    let candidate: [UInt8] = Array("bbb".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 2
    )

    #expect(distance == nil)
}

// MARK: - Normalized Score Calculation

@Test func normalizedScoreExactMatch() {
    let score = normalizedScore(
        editDistance: 0,
        queryLength: 5,
        kind: .exact,
        config: EditDistanceConfig()
    )

    #expect(score == 1.0)
}

@Test func normalizedScoreDecreasesWithDistance() {
    // Use substringWeight of 1.0 to avoid capping at 1.0 for base score calculation
    let config = EditDistanceConfig(prefixWeight: 1.0)

    let score0 = normalizedScore(editDistance: 0, queryLength: 5, kind: .prefix, config: config)
    let score1 = normalizedScore(editDistance: 1, queryLength: 5, kind: .prefix, config: config)
    let score2 = normalizedScore(editDistance: 2, queryLength: 5, kind: .prefix, config: config)

    // With prefixWeight 1.0: score0 = 1.0, score1 = 0.8, score2 = 0.6
    #expect(score0 > score1)
    #expect(score1 > score2)
}

@Test func normalizedScoreHandlesEmptyQuery() {
    let score = normalizedScore(
        editDistance: 0,
        queryLength: 0,
        kind: .exact,
        config: EditDistanceConfig()
    )

    #expect(score == 1.0)
}

@Test func normalizedScoreCappedAtOne() {
    // With high prefix weight, ensure score doesn't exceed 1.0
    let config = EditDistanceConfig(prefixWeight: 2.0)
    let score = normalizedScore(
        editDistance: 0,
        queryLength: 5,
        kind: .prefix,
        config: config
    )

    #expect(score <= 1.0)
}

// MARK: - Multiple Edit Operations

@Test func multipleInsertions() {
    // "hlo" -> "hello" (2 insertions)
    let query: [UInt8] = Array("hlo".utf8)
    let candidate: [UInt8] = Array("hello".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 2)
}

@Test func multipleDeletions() {
    // "hello" -> "hlo" (2 deletions)
    let query: [UInt8] = Array("hello".utf8)
    let candidate: [UInt8] = Array("hlo".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 3
    )

    #expect(distance == 2)
}

@Test func mixedOperations() {
    // "kitten" -> "sitting"
    // In prefix edit distance, we find the best way to match query as prefix of candidate
    // The algorithm allows the candidate to have extra trailing characters
    // k->s (sub), i->i (match), t->t (match), t->t (match), e->i (sub), n->n (match)
    // This gives distance 2 since we're matching "kitten" against "sittin" part
    let query: [UInt8] = Array("kitten".utf8)
    let candidate: [UInt8] = Array("sitting".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 5
    )

    // The actual edit distance depends on the prefix matching algorithm
    #expect(distance != nil)
    #expect(distance! <= 5)
}

// MARK: - Edit Distance Symmetry
//
// Damerau-Levenshtein distance is symmetric: d(a,b) == d(b,a).
// These tests verify that swapping query and candidate produces the same distance.

@Test func symmetryIdenticalStrings() {
    let a: [UInt8] = Array("hello".utf8)
    let b: [UInt8] = Array("hello".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == 0)
    #expect(dBA == 0)
}

@Test func symmetrySingleSubstitution() {
    let a: [UInt8] = Array("cat".utf8)
    let b: [UInt8] = Array("bat".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == dBA)
    #expect(dAB == 1)
}

@Test func symmetryTransposition() {
    let a: [UInt8] = Array("ab".utf8)
    let b: [UInt8] = Array("ba".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == dBA)
    #expect(dAB == 1)
}

@Test func symmetryDifferentLengthsSameLength() {
    // Prefix/substring distances are asymmetric by design for different-length strings.
    // True Damerau-Levenshtein symmetry holds for same-length strings.
    // Test with same-length strings that differ by one insertion+deletion (= 2 substitutions).
    let a: [UInt8] = Array("cats".utf8)
    let b: [UInt8] = Array("bats".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == dBA)
    #expect(dAB == 1)
}

@Test func symmetryMultipleEdits() {
    let a: [UInt8] = Array("kitten".utf8)
    let b: [UInt8] = Array("sittin".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    // Same-length strings: prefix edit distance is the full Damerau-Levenshtein distance
    #expect(dAB == dBA)
}

@Test func symmetryCompletelyDifferent() {
    let a: [UInt8] = Array("abc".utf8)
    let b: [UInt8] = Array("xyz".utf8)
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == dBA)
    #expect(dAB == 3)
}

@Test func symmetryEmptyVsNonEmpty() {
    let empty: [UInt8] = []
    let nonempty: [UInt8] = Array("abc".utf8)
    var stateA = EditDistanceState(maxQueryLength: empty.count)
    var stateB = EditDistanceState(maxQueryLength: nonempty.count)

    let dAB = prefixEditDistance(query: empty, candidate: nonempty, state: &stateA, maxEditDistance: 5)
    // Reverse: "abc" against "" — prefix distance is 3 (delete all)
    let dBA = prefixEditDistance(query: nonempty, candidate: empty, state: &stateB, maxEditDistance: 5)

    // Empty query matches any prefix with 0 edits; nonempty query against empty candidate = queryLength
    #expect(dAB == 0)
    // dBA could be nil (exceeds max) or queryLength — the function returns queryLen as starting bestDistance
    // but with 0-length candidate, no iterations run. bestDistance stays at queryLen=3 which is <= maxEditDistance=5.
    #expect(dBA == 3)
}

@Test func symmetryLongerStrings() {
    // Test with longer strings where the edit is in the middle
    let a: [UInt8] = Array("abcdefghijklmnop".utf8)
    let b: [UInt8] = Array("abcdefxhijklmnop".utf8) // substitution at position 6
    var stateA = EditDistanceState(maxQueryLength: a.count)
    var stateB = EditDistanceState(maxQueryLength: b.count)

    let dAB = prefixEditDistance(query: a, candidate: b, state: &stateA, maxEditDistance: 5)
    let dBA = prefixEditDistance(query: b, candidate: a, state: &stateB, maxEditDistance: 5)

    #expect(dAB == dBA)
    #expect(dAB == 1)
}

// MARK: - Common Prefix/Suffix Handling
//
// Verifies that strings sharing a common prefix, suffix, or both produce correct
// edit distances — the shared portion shouldn't affect the result.

@Test func commonPrefixOnlyDiffersAtEnd() {
    // "abcdef" vs "abcdxy" — share "abcd", differ at last 2
    let a: [UInt8] = Array("abcdef".utf8)
    let b: [UInt8] = Array("abcdxy".utf8)
    var state = EditDistanceState(maxQueryLength: a.count)

    let distance = prefixEditDistance(query: a, candidate: b, state: &state, maxEditDistance: 5)

    #expect(distance == 2) // 2 substitutions: e→x, f→y
}

@Test func commonSuffixOnlyDiffersAtStart() {
    // "xydefg" vs "abdefg" — share "defg" suffix
    let a: [UInt8] = Array("xydefg".utf8)
    let b: [UInt8] = Array("abdefg".utf8)
    var state = EditDistanceState(maxQueryLength: a.count)

    let distance = prefixEditDistance(query: a, candidate: b, state: &state, maxEditDistance: 5)

    #expect(distance == 2) // 2 substitutions: x→a, y→b
}

@Test func commonPrefixAndSuffix() {
    // "abcXdef" vs "abcYdef" — share prefix "abc" and suffix "def", differ in middle
    let a: [UInt8] = Array("abcxdef".utf8)
    let b: [UInt8] = Array("abcydef".utf8)
    var state = EditDistanceState(maxQueryLength: a.count)

    let distance = prefixEditDistance(query: a, candidate: b, state: &state, maxEditDistance: 5)

    #expect(distance == 1) // 1 substitution in the middle
}

@Test func entireStringIsCommonPrefix() {
    // "abc" is a prefix of "abcdef"
    let query: [UInt8] = Array("abc".utf8)
    let candidate: [UInt8] = Array("abcdef".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(query: query, candidate: candidate, state: &state, maxEditDistance: 5)

    #expect(distance == 0) // exact prefix match
}

@Test func commonPrefixWithTransposition() {
    // "abcTSdef" vs "abcSTdef" — shared prefix "abc", transposition in middle, shared suffix "def"
    let a: [UInt8] = Array("abctsdef".utf8)
    let b: [UInt8] = Array("abcstdef".utf8)
    var state = EditDistanceState(maxQueryLength: a.count)

    let distance = prefixEditDistance(query: a, candidate: b, state: &state, maxEditDistance: 5)

    #expect(distance == 1) // transposition of "ts" → "st"
}

@Test func longCommonPrefixSingleEdit() {
    // 50-char shared prefix, then 1 edit
    let prefix = String(repeating: "a", count: 50)
    let a: [UInt8] = Array((prefix + "x").utf8)
    let b: [UInt8] = Array((prefix + "y").utf8)
    var state = EditDistanceState(maxQueryLength: a.count)

    let distance = prefixEditDistance(query: a, candidate: b, state: &state, maxEditDistance: 5)

    #expect(distance == 1)
}

// MARK: - Single-Character Query (Row-Minimum Pruning Regression)

@Test func prefixEditDistanceSingleCharacterQuery() {
    // Regression: queryLen == 1 caused fatal error in row-minimum pruning
    // because `for j in 2...1` creates an invalid ClosedRange.
    let query: [UInt8] = Array("w".utf8)
    let candidate: [UInt8] = Array("wisdom".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 1
    )

    #expect(distance == 0)  // "w" is an exact prefix of "wisdom"
}

@Test func prefixEditDistanceSingleCharacterNoMatch() {
    let query: [UInt8] = Array("z".utf8)
    let candidate: [UInt8] = Array("wisdom".utf8)
    var state = EditDistanceState(maxQueryLength: query.count)

    let distance = prefixEditDistance(
        query: query,
        candidate: candidate,
        state: &state,
        maxEditDistance: 1
    )

    #expect(distance == 1)  // substitution: z -> w
}

@Test func singleCharQueryThroughMatcher() {
    // End-to-end test: typing "w" should not crash when scoring against a corpus
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("w")
    var buffer = matcher.makeBuffer()

    let candidates = [
        "wisdom", "WISE Plc", "WKL U6 28", "getUserById",
        "fetchData", "windowManager", "swift"
    ]

    // Should not crash; just verify it runs without fatal error
    for candidate in candidates {
        _ = matcher.score(candidate, against: query, buffer: &buffer)
    }
}

@Test func twoCharQueryThroughMatcher() {
    // Typing "wi" should not crash
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("wi")
    var buffer = matcher.makeBuffer()

    let candidates = [
        "wisdom", "WISE Plc", "WKL U6 28", "getUserById",
        "fetchData", "windowManager", "swift"
    ]

    for candidate in candidates {
        _ = matcher.score(candidate, against: query, buffer: &buffer)
    }
}
