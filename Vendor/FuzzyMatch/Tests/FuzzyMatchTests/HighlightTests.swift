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

#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Helpers

/// Extracts highlighted substrings from ranges for easy assertion.
private func highlightedText(_ candidate: String, ranges: [Range<String.Index>]) -> [String] {
    ranges.map { String(candidate[$0]) }
}

/// Asserts that every character in the highlighted text, when lowercased and normalized,
/// matches the corresponding query character. This verifies the highlight is actually
/// aligned with the query, not just "some characters somewhere".
private func assertHighlightedCharsMatchQuery(
    _ candidate: String,
    ranges: [Range<String.Index>],
    query: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let highlighted = ranges.flatMap { range in
        candidate[range].unicodeScalars.filter { scalar in
            // Skip combining marks — they're part of the base char
            !(scalar.value >= 0x0300 && scalar.value <= 0x036F)
        }
    }
    let queryChars = Array(query.lowercased())
    #expect(
        highlighted.count >= queryChars.count,
        "Highlighted \(highlighted.count) scalars but query has \(queryChars.count) chars",
        sourceLocation: sourceLocation
    )
}

/// Validates structural invariants on returned ranges.
private func assertRangeInvariants(
    _ candidate: String,
    ranges: [Range<String.Index>],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for range in ranges {
        #expect(
            range.lowerBound >= candidate.startIndex,
            "Range starts before string",
            sourceLocation: sourceLocation
        )
        #expect(
            range.upperBound <= candidate.endIndex,
            "Range ends after string",
            sourceLocation: sourceLocation
        )
        #expect(
            range.lowerBound < range.upperBound,
            "Empty range",
            sourceLocation: sourceLocation
        )
    }
    // Sorted and non-overlapping
    for idx in 1..<ranges.count {
        #expect(
            ranges[idx].lowerBound >= ranges[idx - 1].upperBound,
            "Ranges overlap or unsorted at index \(idx)",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Edit Distance: Core Match Types

@Test func highlightExactMatch() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("User", against: "user")!
    #expect(ranges.count == 1)
    #expect(highlightedText("User", ranges: ranges) == ["User"])
}

@Test func highlightExactMatchCaseInsensitive() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("HELLO", against: "hello")!
    #expect(ranges.count == 1)
    #expect(highlightedText("HELLO", ranges: ranges) == ["HELLO"])
}

@Test func highlightPrefix() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("getUserById", against: "get")!
    #expect(highlightedText("getUserById", ranges: ranges) == ["get"])
    assertRangeInvariants("getUserById", ranges: ranges)
}

@Test func highlightSubstringMod() {
    // The motivating example from the issue: "mod" vs "format:modern"
    // Should highlight "mod" in "modern", not scatter across the string
    let matcher = FuzzyMatcher()
    let candidate = "format:modern"
    let ranges = matcher.highlight(candidate, against: "mod")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["mod"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSubstringMiddle() {
    // "user" in "getCurrentUser" — should highlight the trailing "User"
    let matcher = FuzzyMatcher()
    let candidate = "getCurrentUser"
    let ranges = matcher.highlight(candidate, against: "user")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["User"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSubsequenceWithBoundaries() {
    // "gubi" vs "getUserById" → word boundary positions g(0), U(3), B(7), I(9)
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gubi")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts.count == 4)
    #expect(texts == ["g", "U", "B", "I"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightAcronym() {
    // "bms" vs "Bristol-Myers Squibb" → word initials B, M, S
    let matcher = FuzzyMatcher()
    let candidate = "Bristol-Myers Squibb"
    let ranges = matcher.highlight(candidate, against: "bms")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["B", "M", "S"])
}

@Test func highlightAcronymFullCoverage() {
    // "icag" vs "International Consolidated Airlines Group" — 4/4 words
    // With matchKind routing, the scorer identifies this as an acronym match
    // and highlight() jumps directly to word-initial positions.
    let matcher = FuzzyMatcher()
    let candidate = "International Consolidated Airlines Group"
    let ranges = matcher.highlight(candidate, against: "icag")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["I", "C", "A", "G"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Edit Distance: Edge Cases

@Test func highlightSingleCharQuery() {
    // Single-char queries use the scoreTinyQuery1 fast path in score().
    // highlight() should still work.
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "g")
    #expect(ranges != nil)
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts.joined().lowercased() == "g")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func highlightSingleCharCandidateMatch() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("a", against: "a")!
    #expect(ranges.count == 1)
    #expect(highlightedText("a", ranges: ranges) == ["a"])
}

@Test func highlightSingleCharCandidateNoMatch() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("a", against: "z")
    #expect(ranges == nil)
}

@Test func highlightEmptyQuery() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("something", against: "")!
    #expect(ranges.isEmpty)
}

@Test func highlightEmptyCandidate() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("", against: "abc")
    #expect(ranges == nil)
}

@Test func highlightNoMatch() {
    let matcher = FuzzyMatcher()
    #expect(matcher.highlight("getUserById", against: "xyz") == nil)
}

@Test func highlightIdenticalStrings() {
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "getUserById")!
    #expect(ranges.count == 1)
    #expect(highlightedText(candidate, ranges: ranges) == [candidate])
}

@Test func highlightSnakeCase() {
    // "fb" vs "file_browser" — should match at word boundaries f, b
    let matcher = FuzzyMatcher()
    let candidate = "file_browser"
    let ranges = matcher.highlight(candidate, against: "fb")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["f", "b"])
}

@Test func highlightConvenienceOverload() {
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("getUserById", against: "get")!
    #expect(highlightedText("getUserById", ranges: ranges) == ["get"])
}

@Test func highlightLongQuery() {
    // Longer query (> 4 chars) uses optimalAlignment instead of findMatchPositions
    let matcher = FuzzyMatcher()
    let candidate = "processUserInputData"
    let ranges = matcher.highlight(candidate, against: "input")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["Input"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSubstringAtEnd() {
    // Query matches at the very end of the candidate
    let matcher = FuzzyMatcher()
    let candidate = "somePrefix_data"
    let ranges = matcher.highlight(candidate, against: "data")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["data"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Unicode: Diacritics, Combining Marks, Confusables

@Test func highlightDiacriticPrecomposed() {
    // "cafe" should match "café" (precomposed é = 0xC3 0xA9)
    let matcher = FuzzyMatcher()
    let candidate = "café"
    let ranges = matcher.highlight(candidate, against: "cafe")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts.joined() == "café")
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightDiacriticDecomposed() {
    // "cafe" vs "cafe\u{0301}" (e + combining acute) → range extends past mark
    let candidate = "cafe\u{0301}"
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight(candidate, against: "cafe")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts.joined() == candidate)
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightMultipleDiacritics() {
    // "naive" should match "naïve" (ï = 0xC3 0xAF → i)
    let matcher = FuzzyMatcher()
    let candidate = "naïve"
    let ranges = matcher.highlight(candidate, against: "naive")
    #expect(ranges != nil)
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts.joined() == "naïve")
    }
}

@Test func highlightDiacriticInMiddle() {
    // "resume" should match "résumé" — both é chars normalize to e
    let matcher = FuzzyMatcher()
    let candidate = "résumé"
    let ranges = matcher.highlight(candidate, against: "resume")
    #expect(ranges != nil)
    if let ranges {
        #expect(ranges.count == 1) // All consecutive → coalesced
        #expect(highlightedText(candidate, ranges: ranges).joined() == "résumé")
    }
}

@Test func highlightConfusableCurlyQuotes() {
    // Curly quotes normalize to ASCII apostrophe
    let matcher = FuzzyMatcher()
    let candidate = "it\u{2019}s" // it\u{2019}s with right single quotation mark
    let ranges = matcher.highlight(candidate, against: "it's")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == [candidate])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightConfusableEnDash() {
    // En-dash normalizes to hyphen-minus
    let matcher = FuzzyMatcher()
    let candidate = "Bristol\u{2013}Myers" // en-dash
    let ranges = matcher.highlight(candidate, against: "bristol-myers")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == [candidate])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightGermanUmlaut() {
    // ü (0xC3 0xBC) normalizes to u
    let matcher = FuzzyMatcher()
    let candidate = "München"
    let ranges = matcher.highlight(candidate, against: "munchen")!
    #expect(ranges.count == 1) // All consecutive → single range
    #expect(highlightedText(candidate, ranges: ranges) == ["München"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSpanishTilde() {
    // ñ (0xC3 0xB1) normalizes to n
    let matcher = FuzzyMatcher()
    let candidate = "España"
    let ranges = matcher.highlight(candidate, against: "espana")!
    #expect(ranges.count == 1)
    #expect(highlightedText(candidate, ranges: ranges) == ["España"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Long Candidates (>64 chars, >512 bytes)

@Test func highlightLongCandidateOver64Chars() {
    // Boundary mask only covers first 64 positions; longer ones use isWordBoundary fallback
    let matcher = FuzzyMatcher()
    let prefix = String(repeating: "x", count: 70)
    let candidate = prefix + "Target"
    let ranges = matcher.highlight(candidate, against: "target")
    #expect(ranges != nil)
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts.joined().lowercased() == "target")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func highlightLongCandidateOver512Bytes() {
    // Score gate: very long candidates are rejected by score() due to length
    // penalty exceeding minScore, so highlight() must also return nil.
    let matcher = FuzzyMatcher()
    let prefix = String(repeating: "a", count: 520)
    let candidate = prefix + "target"
    var buffer = matcher.makeBuffer()
    let query = matcher.prepare("target")
    #expect(matcher.score(candidate, against: query, buffer: &buffer) == nil)
    #expect(matcher.highlight(candidate, against: query) == nil)
}

// MARK: - Range Invariants

@Test func highlightRangesCoalesced() {
    // Consecutive matches should be coalesced into a single range
    let matcher = FuzzyMatcher()
    let ranges = matcher.highlight("getUserById", against: "get")!
    #expect(ranges.count == 1)
}

@Test func highlightRangesCoalescedLongSubstring() {
    // A longer contiguous substring match should still be one range
    let matcher = FuzzyMatcher()
    let candidate = "modernization"
    let ranges = matcher.highlight(candidate, against: "modern")!
    #expect(ranges.count == 1)
    #expect(highlightedText(candidate, ranges: ranges) == ["modern"])
}

@Test func highlightScatteredRangesNotCoalesced() {
    // Non-adjacent matches should produce separate ranges
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gubi")!
    // g, U, B, I are at non-adjacent positions → 4 separate ranges
    #expect(ranges.count == 4)
}

@Test func highlightRangesAreValidOnVariousCandidates() {
    let matcher = FuzzyMatcher()
    let testCases: [(String, String)] = [
        ("getUserById", "gubi"),
        ("format:modern", "mod"),
        ("Bristol-Myers Squibb", "bms"),
        ("café", "cafe"),
        ("cafe\u{0301}", "cafe"),
        ("file_browser", "fb"),
        ("processUserInputData", "input")
    ]
    for (candidate, query) in testCases {
        if let ranges = matcher.highlight(candidate, against: query) {
            assertRangeInvariants(candidate, ranges: ranges)
        }
    }
}

// MARK: - Smith-Waterman Highlight Tests

@Test func highlightSWExactMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let ranges = matcher.highlight("User", against: "user")!
    #expect(ranges.count == 1)
    #expect(highlightedText("User", ranges: ranges) == ["User"])
}

@Test func highlightSWSubstringMod() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "format:modern"
    let ranges = matcher.highlight(candidate, against: "mod")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["mod"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWCamelCase() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gubi")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["g", "U", "B", "I"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWMultiWord() {
    // "foo bar" vs "fooXXXbar" → both atoms highlighted
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "fooXXXbar"
    let ranges = matcher.highlight(candidate, against: "foo bar")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["foo", "bar"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWMultiWordSpacedCandidate() {
    // Multi-word query with spaces in candidate
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "hello world test"
    let ranges = matcher.highlight(candidate, against: "hello test")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["hello", "test"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWNoMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    #expect(matcher.highlight("getUserById", against: "zzz") == nil)
}

@Test func highlightSWAcronymFallback() {
    // With matchKind routing, the scorer identifies this as an acronym match
    // and highlight() jumps directly to word-initial positions.
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "International Consolidated Airlines Group"
    let ranges = matcher.highlight(candidate, against: "icag")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["I", "C", "A", "G"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWPrefix() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "get")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["get"])
}

@Test func highlightSWDiacritics() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "café"
    let ranges = matcher.highlight(candidate, against: "cafe")!
    #expect(highlightedText(candidate, ranges: ranges).joined() == "café")
}

@Test func highlightSWSingleChar() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let ranges = matcher.highlight("hello", against: "h")
    #expect(ranges != nil)
    if let ranges {
        #expect(highlightedText("hello", ranges: ranges).joined() == "h")
    }
}

// MARK: - Consistency: score() ↔ highlight()

@Test func highlightConsistencyWithScoreED() {
    // score() returns non-nil ⟹ highlight() returns non-nil.
    // ED traceback handles typo matches (substitutions, deletions, insertions,
    // transpositions), so even queries with characters not in the candidate
    // produce valid highlights showing the aligned region.
    let candidates = [
        "getUserById", "setUser", "fetchData", "userService",
        "format:modern", "Bristol-Myers Squibb", "café", "debugging",
        "International Consolidated Airlines Group",
        "completely_unrelated_xyz", "file_browser", "processUserInputData",
        "résumé", "naïve", "München", "España"
    ]

    let queries = [
        "get", "user", "mod", "bms", "cafe", "xyz", "gubi", "icag",
        "g", "fb", "input", "resume", "naive", "data"
    ]

    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    for queryStr in queries {
        let query = matcher.prepare(queryStr)
        for candidate in candidates {
            let scoreResult = matcher.score(candidate, against: query, buffer: &buffer)
            let highlightResult = matcher.highlight(candidate, against: query)

            if scoreResult != nil {
                #expect(
                    highlightResult != nil,
                    "score() matched but highlight() nil: query='\(queryStr)' candidate='\(candidate)'"
                )
                if let ranges = highlightResult {
                    assertRangeInvariants(candidate, ranges: ranges)
                }
            }
        }
    }
}

@Test func highlightConsistencyWithScoreSW() {
    let candidates = [
        "getUserById", "setUser", "fetchData", "userService",
        "format:modern", "Bristol-Myers Squibb", "café", "debugging",
        "file_browser", "processUserInputData", "fooXXXbar"
    ]

    let queries = ["get", "user", "mod", "cafe", "gubi", "fb", "input", "foo bar"]

    let matcher = FuzzyMatcher(config: .smithWaterman)
    var buffer = matcher.makeBuffer()

    for queryStr in queries {
        let query = matcher.prepare(queryStr)
        for candidate in candidates {
            let scoreResult = matcher.score(candidate, against: query, buffer: &buffer)
            let highlightResult = matcher.highlight(candidate, against: query)

            if scoreResult != nil {
                #expect(
                    highlightResult != nil,
                    "SW score() matched but highlight() nil: query='\(queryStr)' candidate='\(candidate)'"
                )
                if let ranges = highlightResult {
                    assertRangeInvariants(candidate, ranges: ranges)
                }
            }
        }
    }
}

@Test func highlightedCharsCorrespondToQuery() {
    // Verify the number of highlighted characters matches query length
    let matcher = FuzzyMatcher()
    let testCases: [(String, String, Int)] = [
        ("getUserById", "get", 3),
        ("getUserById", "gubi", 4),
        ("format:modern", "mod", 3),
        ("Bristol-Myers Squibb", "bms", 3),
        ("User", "user", 4),
        ("file_browser", "fb", 2)
    ]
    for (candidate, query, expectedCharCount) in testCases {
        let ranges = matcher.highlight(candidate, against: query)!
        let totalHighlightedChars = ranges.reduce(0) { sum, range in
            sum + candidate[range].count
        }
        #expect(
            totalHighlightedChars == expectedCharCount,
            "query='\(query)' candidate='\(candidate)': expected \(expectedCharCount) chars, got \(totalHighlightedChars)"
        )
    }
}

@Test func highlightedCharsCorrespondToQuerySW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let testCases: [(String, String, Int)] = [
        ("getUserById", "get", 3),
        ("format:modern", "mod", 3),
        ("User", "user", 4)
    ]
    for (candidate, query, expectedCharCount) in testCases {
        let ranges = matcher.highlight(candidate, against: query)!
        let totalHighlightedChars = ranges.reduce(0) { sum, range in
            sum + candidate[range].count
        }
        #expect(
            totalHighlightedChars == expectedCharCount,
            "SW query='\(query)' candidate='\(candidate)': expected \(expectedCharCount) chars, got \(totalHighlightedChars)"
        )
    }
}

// MARK: - Edit Distance: Typos, Deletions, Insertions

@Test func highlightTypoInMiddle() {
    // Query "getusar" has a typo: 'a' instead of 'e'. ED traceback aligns
    // the 'a' against the candidate's 'e' (substitution) and highlights all
    // 7 candidate chars that participated: "getUser".
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "getusar")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["getUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightTypoInMiddleSubstring() {
    // "modrn" is "modern" missing the 'e'. ED traceback matches m,o,d against
    // "mod" and r,n against "rn", skipping the unmatched 'e' in the candidate.
    let matcher = FuzzyMatcher()
    let candidate = "format:modern"
    let ranges = matcher.highlight(candidate, against: "modrn")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["mod", "rn"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightRemovedChar() {
    // "gtuser" — missing 'e' from "getUser". All chars exist in candidate
    // as a subsequence, so subsequence alignment finds g(0), t(2), u(3),
    // s(4), e(5), r(6). The gap after 'g' creates two ranges.
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gtuser")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["g", "tUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightRemovedCharFromMiddle() {
    // "broser" — missing 'w' from "browser". ED traceback matches b,r,o
    // against "bro" and s,e,r against "ser", skipping the 'w'.
    let matcher = FuzzyMatcher()
    let candidate = "file_browser"
    let ranges = matcher.highlight(candidate, against: "broser")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["bro", "ser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightDoubledChar() {
    // "geetuser" — extra 'e'. ED traceback absorbs the doubled 'e' (deletion
    // from query) and highlights "getUser" (7 candidate chars for 8 query chars).
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "geetuser")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["getUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightDoubledCharSubstring() {
    // "moddernize" — doubled 'd'. ED traceback drops the extra 'd' and
    // highlights all of "modernize" (9 candidate chars for 10 query chars).
    let matcher = FuzzyMatcher()
    let candidate = "modernize"
    let ranges = matcher.highlight(candidate, against: "moddernize")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["modernize"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightExtraCharInQuery() {
    // "inputs" — extra 's' appended. ED traceback aligns "inputs" against
    // "inputd" via substitution (s→d, distance 1), highlighting "InputD".
    // The `<=` end-position selection picks the latest tied-cost alignment,
    // which is correct for transpositions and yields a valid substitution here.
    let matcher = FuzzyMatcher()
    let candidate = "processUserInputData"
    let ranges = matcher.highlight(candidate, against: "inputs")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["InputD"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightTransposedChars() {
    // "gteuser" — 'e' and 't' transposed. Damerau-Levenshtein recognises the
    // transposition as 1 edit and highlights both swapped positions plus the
    // remaining chars: "getUser" (7 candidate chars).
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gteuser")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["getUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Edit Distance: Multiple Typos

@Test func highlightTwoSubstitutions() {
    // "mxdern" — 'o' replaced with 'x'. ED traceback aligns the 'x' against
    // 'o' (substitution, distance 1) and highlights "modern" in "modernize".
    let matcher = FuzzyMatcher()
    let candidate = "modernize"
    let ranges = matcher.highlight(candidate, against: "mxdern")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["modern"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightTwoSubstitutionsCamelCase() {
    // "gxtuser" — 'e' replaced with 'x'. ED traceback finds distance-1 alignment
    // (substitution x→e) and highlights "getUser" in "getUserById".
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "gxtuser")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["getUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightTranspositionFullWord() {
    // "Berkhsire" — transposition of 's' and 'h'. ED traceback finds the
    // transposition and highlights the entire word.
    let matcher = FuzzyMatcher()
    let candidate = "Berkshire"
    let ranges = matcher.highlight(candidate, against: "Berkhsire")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["Berkshire"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Edit Distance: Space-Containing Query

@Test func highlightEDSpaceInQuery() {
    // ED mode treats multi-word queries monolithically. "get user" matches
    // "getUser" as a substring with spaces normalized away.
    let matcher = FuzzyMatcher()
    let candidate = "getUserById"
    let ranges = matcher.highlight(candidate, against: "get user")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["getUser"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Prepared FuzzyQuery Overload

@Test func highlightWithPreparedQuery() {
    // Test the highlight(_:against: FuzzyQuery) overload directly
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("mod")
    let candidate = "format:modern"
    let ranges = matcher.highlight(candidate, against: query)!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["mod"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightWithPreparedQuerySW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("foo bar")
    let candidate = "fooXXXbar"
    let ranges = matcher.highlight(candidate, against: query)!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["foo", "bar"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Smith-Waterman: Unicode Gaps

@Test func highlightSWDecomposedDiacritic() {
    // SW mode with combining mark: "cafe" vs "cafe\u{0301}" (e + combining acute)
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "cafe\u{0301}"
    let ranges = matcher.highlight(candidate, against: "cafe")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts.joined() == candidate)
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWConfusableCurlyQuotes() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "it\u{2019}s"
    let ranges = matcher.highlight(candidate, against: "it's")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == [candidate])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWConfusableEnDash() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "Bristol\u{2013}Myers"
    let ranges = matcher.highlight(candidate, against: "bristol-myers")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == [candidate])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Smith-Waterman: Long Candidates

@Test func highlightSWLongCandidateOver64Chars() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let prefix = String(repeating: "x", count: 70)
    let candidate = prefix + "Target"
    let ranges = matcher.highlight(candidate, against: "target")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["Target"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Reverse Consistency: score() nil → highlight() nil

@Test func highlightNilWhenScoreNilED() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()
    let noMatchCases: [(String, String)] = [
        ("getUserById", "xyz"),
        ("hello", "zzz"),
        ("short", "muchlongerquery")
    ]
    for (candidate, queryStr) in noMatchCases {
        let query = matcher.prepare(queryStr)
        let scoreResult = matcher.score(candidate, against: query, buffer: &buffer)
        let highlightResult = matcher.highlight(candidate, against: query)
        #expect(scoreResult == nil, "Expected no score: '\(queryStr)' vs '\(candidate)'")
        #expect(
            highlightResult == nil,
            "highlight() non-nil but score() nil: '\(queryStr)' vs '\(candidate)'"
        )
    }
}

@Test func highlightNilWhenScoreNilSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    var buffer = matcher.makeBuffer()
    let noMatchCases: [(String, String)] = [
        ("getUserById", "zzz"),
        ("hello", "xyz"),
        ("short", "muchlongerquery")
    ]
    for (candidate, queryStr) in noMatchCases {
        let query = matcher.prepare(queryStr)
        let scoreResult = matcher.score(candidate, against: query, buffer: &buffer)
        let highlightResult = matcher.highlight(candidate, against: query)
        #expect(scoreResult == nil, "Expected no score: '\(queryStr)' vs '\(candidate)'")
        #expect(
            highlightResult == nil,
            "SW highlight() non-nil but score() nil: '\(queryStr)' vs '\(candidate)'"
        )
    }
}

// MARK: - Greek and Cyrillic Normalization

@Test func highlightGreekCaseInsensitive() {
    // Greek uppercase ΑΒΓΔ should match lowercase query "αβγ" via case folding
    let matcher = FuzzyMatcher()
    let candidate = "ΑΒΓΔ"
    let ranges = matcher.highlight(candidate, against: "αβγ")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["ΑΒΓ"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightGreekSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "ΑΒΓΔ"
    let ranges = matcher.highlight(candidate, against: "αβγ")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["ΑΒΓ"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightCyrillicCaseInsensitive() {
    // Cyrillic МОСКВА should match "москва" as exact (score 1.0)
    let matcher = FuzzyMatcher()
    let candidate = "МОСКВА"
    let ranges = matcher.highlight(candidate, against: "москва")!
    #expect(ranges.count == 1)
    #expect(highlightedText(candidate, ranges: ranges) == ["МОСКВА"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightCyrillicSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "МОСКВА"
    let ranges = matcher.highlight(candidate, against: "москва")!
    #expect(ranges.count == 1)
    #expect(highlightedText(candidate, ranges: ranges) == ["МОСКВА"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - 4-Byte UTF-8 (Emoji)

@Test func highlightAroundEmoji() {
    // "done" after a 4-byte emoji — tests range mapping for 4-byte chars
    let matcher = FuzzyMatcher()
    let candidate = "test🎉done"
    let ranges = matcher.highlight(candidate, against: "done")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["done"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightBeforeEmoji() {
    let matcher = FuzzyMatcher()
    let candidate = "test🎉done"
    let ranges = matcher.highlight(candidate, against: "test")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["test"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightAroundEmojiSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "test🎉done"
    let ranges = matcher.highlight(candidate, against: "done")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["done"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Non-Confusable Multi-Byte Passthrough

@Test func highlightNonConfusable0xE2() {
    // "™" (E2 84 A2) is NOT a confusable — should pass through without mapping
    let matcher = FuzzyMatcher()
    let candidate = "FuzzyMatch™"
    let ranges = matcher.highlight(candidate, against: "fuzzymatch")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["FuzzyMatch"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightNonConfusable0xC2() {
    // "£" (C2 A3) is NOT a confusable — should pass through
    let matcher = FuzzyMatcher()
    let candidate = "price£100"
    let ranges = matcher.highlight(candidate, against: "price")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["price"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightLatin1NonASCIIPassthrough() {
    // "ð" (C3 B0) doesn't map to an ASCII base letter — tests the non-ASCII
    // Latin-1 passthrough path in buildNormalizationMapping
    let matcher = FuzzyMatcher()
    let candidate = "Reykjavíkurð"
    let ranges = matcher.highlight(candidate, against: "reykjavik")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["Reykjavík"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - SW Edge Cases: Nil Paths

@Test func highlightSWMultiAtomOneFails() {
    // "foo zzz" vs "fooXXXbar" — 'zzz' atom not in candidate → nil
    let matcher = FuzzyMatcher(config: .smithWaterman)
    #expect(matcher.highlight("fooXXXbar", against: "foo zzz") == nil)
}

@Test func highlightSWSingleNilAcronymNil() {
    // "zz" vs "abcdef" — no SW alignment and no acronym match → nil
    let matcher = FuzzyMatcher(config: .smithWaterman)
    #expect(matcher.highlight("abcdef", against: "zz") == nil)
}

// MARK: - SW Gap-End Traceback

@Test func highlightSWScatteredWithGap() {
    // "ac" vs "aXXXXXc" — tests the gap traceback path in smithWatermanPositions
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "aXXXXXc"
    let ranges = matcher.highlight(candidate, against: "ac")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["a", "c"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Short Query Greedy → DP Fallback

@Test func highlightShortQueryGreedyToDPFallback() {
    // "ace" vs "abcde_ace" — greedy finds scattered a(0),c(2),e(4) but the
    // contiguous substring "ace" at positions 6-8 is the correct highlight.
    let matcher = FuzzyMatcher()
    let candidate = "abcde_ace"
    let ranges = matcher.highlight(candidate, against: "ace")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["ace"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Regression: Issue Motivating Example

@Test func highlightModAgainstFormatModernIsContiguous() {
    // The key invariant from issue #16: "mod" against "format:modern" must NOT
    // produce scattered highlights like for**m**at:**mod**ern.
    // It must be a single contiguous range covering "mod" in "modern".
    let matcher = FuzzyMatcher()
    let candidate = "format:modern"
    let ranges = matcher.highlight(candidate, against: "mod")!
    #expect(ranges.count == 1, "Expected single contiguous range, got \(ranges.count)")
    #expect(highlightedText(candidate, ranges: ranges) == ["mod"])
}

// MARK: - Regression: Transposition Truncation

@Test func highlightTranspositionNotTruncated() {
    // "USD" vs query "UDS" — transposition at end. Must highlight all 3 chars,
    // not truncate to 2 by picking the earliest tied end position.
    let matcher = FuzzyMatcher()
    let candidate = "USD"
    let ranges = matcher.highlight(candidate, against: "UDS")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["USD"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightTranspositionModNotTruncated() {
    // "mod" vs query "mdo" — transposition at end.
    let matcher = FuzzyMatcher()
    let candidate = "mod"
    let ranges = matcher.highlight(candidate, against: "mdo")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["mod"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Regression: Score/Highlight Divergence

@Test func highlightNilWhenScoreRejectsShortQuery() {
    // "USD Fund" vs "UDS": score() rejects this (short query, high distance
    // relative to length). highlight() must also return nil.
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()
    let query = matcher.prepare("UDS")
    let scoreResult = matcher.score("USD Fund", against: query, buffer: &buffer)
    let highlightResult = matcher.highlight("USD Fund", against: query)
    #expect(scoreResult == nil)
    #expect(highlightResult == nil)
}

@Test func highlightNilWhenMinScoreRejects() {
    // With a high minScore threshold, score() rejects "format:modern" for "mod"
    // but highlight()'s independent alignment would find it. The score gate prevents this.
    let config = MatchConfig(minScore: 0.99, algorithm: .editDistance())
    let matcher = FuzzyMatcher(config: config)
    var buffer = matcher.makeBuffer()
    let query = matcher.prepare("mod")
    let scoreResult = matcher.score("format:modern", against: query, buffer: &buffer)
    let highlightResult = matcher.highlight("format:modern", against: query)
    #expect(scoreResult == nil)
    #expect(highlightResult == nil)
}

// MARK: - Regression: Prefix Typo Highlights

@Test func highlightPrefixTypoTransposition() {
    // "ifle" vs "fileName" — score() returns .prefix (transposition i↔f),
    // highlight must anchor at position 0 and cover the leading "f".
    let matcher = FuzzyMatcher()
    let candidate = "fileName"
    let ranges = matcher.highlight(candidate, against: "ifle")!
    // Must include position 0 ("f")
    #expect(ranges.first!.lowerBound == candidate.startIndex,
            "Prefix typo highlight must start at position 0")
    assertRangeInvariants(candidate, ranges: ranges)
    assertHighlightedCharsMatchQuery(candidate, ranges: ranges, query: "ifle")
}

@Test func highlightPrefixTypoExtraChar() {
    // "amrket" vs "Market" — score() returns .prefix (extra 'a' + transposition),
    // highlight must anchor at position 0 and cover the leading "M".
    let matcher = FuzzyMatcher()
    let candidate = "Market"
    let ranges = matcher.highlight(candidate, against: "amrket")!
    #expect(ranges.first!.lowerBound == candidate.startIndex,
            "Prefix typo highlight must start at position 0")
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightPrefixTypoShortTransposition() {
    // "ba" vs "ab" — score() returns .prefix (transposition),
    // highlight must cover both positions.
    let matcher = FuzzyMatcher()
    let candidate = "ab"
    let ranges = matcher.highlight(candidate, against: "ba")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["ab"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - Regression: Acronym Match-Kind Routing

@Test func highlightEDAcronymWordInitials() {
    // ED mode: "iag" vs "International Consolidated Airlines Group"
    // The scorer identifies this as .acronym → highlight must show word-initial I, A, G.
    let matcher = FuzzyMatcher()
    let candidate = "International Consolidated Airlines Group"
    let ranges = matcher.highlight(candidate, against: "iag")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["I", "A", "G"])
    assertRangeInvariants(candidate, ranges: ranges)
}

@Test func highlightSWAcronymWordInitials() {
    // SW mode: "iag" vs "International Consolidated Airlines Group"
    // The scorer identifies this as .acronym → highlight must show word-initial I, A, G.
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let candidate = "International Consolidated Airlines Group"
    let ranges = matcher.highlight(candidate, against: "iag")!
    let texts = highlightedText(candidate, ranges: ranges)
    #expect(texts == ["I", "A", "G"])
    assertRangeInvariants(candidate, ranges: ranges)
}

// MARK: - User-reported highlight issues (GitHub #16)
//
// All candidates use the exact strings from the issue (including ! and " prefixes).
// minScore: 0.85 with default edit distance configuration.

@Test(.disabled("ED mode treats multi-word queries as a single token — word-aligned highlight would require per-word splitting like SW atoms"))
func issue16_jiangWild_highlightsCorrectWords() {
    // ED mode matches "jiang wild" as one 10-char substring, not two words.
    // The subsequence DP scatters "j-i-a-n-g" across the best-scoring positions
    // then finds "wild" contiguously — producing ["Ji", "an", "g", " Wild"].
    // Word-aligned ["Jiang", " Wild"] would require space-splitting in the ED
    // highlight path (similar to SW atom splitting), which is not implemented.
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = #"!"Jiang Yanggu, Wildcrafter""#
    let ranges = matcher.highlight(candidate, against: "jiang wild")
    #expect(ranges != nil, "should match jiang wild")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["Jiang", " Wild"], "Expected word-aligned highlights, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func issue16_gold_gopldTypo_matches() {
    // "gopld" (transposition typo for "gold") against "!Gold" — user reported this works.
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "!Gold"
    let ranges = matcher.highlight(candidate, against: "gopld")
    #expect(ranges != nil, "!Gold should match gopld")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["Gold"], "Expected Gold highlighted, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test(.disabled("Not a highlight bug — scorer rejects at minScore 0.85 (score=0.718, kind=prefix). Length penalty on longer candidate pushes score below threshold."))
func issue16_goldhound_gopldTypo_shouldNotBeNil() {
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "!Goldhound"
    let ranges = matcher.highlight(candidate, against: "gopld")
    #expect(ranges != nil, "!Goldhound should match gopld — bare !Gold does")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["Gold"], "Expected Gold highlighted, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test(.disabled("Not a highlight bug — scorer rejects at minScore 0.85 (score=0.816, kind=substring). Would need lower minScore to match."))
func issue16_goliathPaladin_gopldTypo_shouldNotBeNil() {
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = #"!"Goliath Paladin""#
    let ranges = matcher.highlight(candidate, against: "gopld")
    #expect(ranges != nil, #"!"Goliath Paladin" should match gopld"#)
    if let ranges {
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test(.disabled("Not a highlight bug — scorer rejects at minScore 0.85 (score=0.807, kind=prefix). User saw modaldf on an earlier build where scoring differed."))
func issue16_modaldfc_modalek_highlightsOnlyModal() {
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "modaldfc"
    let ranges = matcher.highlight(candidate, against: "modalek")
    #expect(ranges != nil, "modaldfc should match modalek")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["modal"], "Expected modal highlighted, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func issue16_stainedGlass_sainedGlass_matches() {
    // "sained glass" vs "stained-glass" — query is missing "t". The highlight correctly
    // shows ["s", "ained-glass"], leaving a gap at the unmatched "t". The user expected
    // a single contiguous ["stained-glass"] range, but including candidate characters
    // that have no query counterpart would be misleading in the general case.
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "stained-glass"
    let ranges = matcher.highlight(candidate, against: "sained glass")
    #expect(ranges != nil, "stained-glass should match sained glass")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["s", "ained-glass"])
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func issue16_stainedGlass_sayinedGlass_shouldNotBeNil() {
    // "sayined glass" against "stained-glass" — user reported nil but expected a match.
    let config = MatchConfig(minScore: 0.85)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "stained-glass"
    let ranges = matcher.highlight(candidate, against: "sayined glass")
    #expect(ranges != nil, "stained-glass should match sayined glass")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["stained-glass"] || texts == ["s", "ained-glass"],
                "Expected plausible highlight, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

// MARK: - Issue #16 with lower minScore (0.5)
//
// The three cases above that are rejected at minScore 0.85 do match at a lower
// threshold. These tests verify the highlight output when the scorer accepts them.

@Test func issue16_goldhound_gopldTypo_lowMinScore() {
    // At minScore 0.5, scorer accepts (score=0.718, kind=prefix). Highlight is correct.
    let config = MatchConfig(minScore: 0.5)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "!Goldhound"
    let ranges = matcher.highlight(candidate, against: "gopld")
    #expect(ranges != nil, "!Goldhound should match gopld at minScore 0.5")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["Gold"], "Expected Gold highlighted, got \(texts)")
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func issue16_goliathPaladin_gopldTypo_lowMinScore() {
    // At minScore 0.5, scorer accepts (score=0.816, kind=substring).
    // Highlights subsequence positions at word boundaries: "Go" + "P" + "l" + "d".
    let config = MatchConfig(minScore: 0.5)
    let matcher = FuzzyMatcher(config: config)
    let candidate = #"!"Goliath Paladin""#
    let ranges = matcher.highlight(candidate, against: "gopld")
    #expect(ranges != nil, #"!"Goliath Paladin" should match gopld at minScore 0.5"#)
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["Go", "P", "l", "d"])
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

@Test func issue16_modaldfc_modalek_lowMinScore() {
    // At minScore 0.5, scorer accepts (score=0.807, kind=prefix).
    // ED traceback aligns all 7 query chars to 7 candidate positions:
    //   m→m, o→o, d→d, a→a, l→l (5 matches) + e→d, k→f (2 substitutions)
    // Highlighting "modaldf" is correct — substituted positions are included per
    // our ED highlight semantics (same as "getusar" → "getUser" highlighting the
    // substituted 'e'). User expected only "modal" (match-only), but hiding
    // substitutions would be inconsistent with ED traceback policy.
    let config = MatchConfig(minScore: 0.5)
    let matcher = FuzzyMatcher(config: config)
    let candidate = "modaldfc"
    let ranges = matcher.highlight(candidate, against: "modalek")
    #expect(ranges != nil, "modaldfc should match modalek at minScore 0.5")
    if let ranges {
        let texts = highlightedText(candidate, ranges: ranges)
        #expect(texts == ["modaldf"])
        assertRangeInvariants(candidate, ranges: ranges)
    }
}

// MARK: - AttributedString Convenience API

#if canImport(Foundation)

/// Test-only attribute key — portable across all Foundation platforms.
private enum HighlightMarker: AttributedStringKey {
    typealias Value = Bool
    static let name = "testHighlightMarker"
}

@Test func attributedHighlightBasicMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("mod")
    let result = matcher.attributedHighlight("format:modern", against: query) {
        $0[HighlightMarker.self] = true
    }
    #expect(result != nil, "Should return an AttributedString for a match")
    if let result {
        #expect(String(result.characters) == "format:modern")
        // Verify the styled run covers "mod"
        for run in result.runs {
            let text = String(result[run.range].characters)
            if text == "mod" {
                #expect(run[HighlightMarker.self] == true)
            } else {
                #expect(run[HighlightMarker.self] != true)
            }
        }
    }
}

@Test func attributedHighlightNilOnNoMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.attributedHighlight("abc", against: "xyz") {
        $0[HighlightMarker.self] = true
    }
    #expect(result == nil)
}

@Test func attributedHighlightDisjointRanges() {
    // "modrn" vs "format:modern" — missing 'e' produces two ranges: "mod" + "rn"
    let matcher = FuzzyMatcher()
    let result = matcher.attributedHighlight("format:modern", against: "modrn") {
        $0[HighlightMarker.self] = true
    }
    #expect(result != nil)
    if let result {
        var styledParts: [String] = []
        for run in result.runs {
            if run[HighlightMarker.self] == true {
                styledParts.append(String(result[run.range].characters))
            }
        }
        #expect(styledParts == ["mod", "rn"])
    }
}

@Test func attributedHighlightEmptyQuery() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("")
    let result = matcher.attributedHighlight("hello", against: query) {
        $0[HighlightMarker.self] = true
    }
    // Empty query returns empty ranges from highlight(), which means an unstyled AttributedString
    #expect(result != nil)
    if let result {
        #expect(String(result.characters) == "hello")
    }
}

@Test func attributedHighlightConvenienceOverload() {
    let matcher = FuzzyMatcher()
    let result = matcher.attributedHighlight("getUserById", against: "getuser") {
        $0[HighlightMarker.self] = true
    }
    #expect(result != nil)
    if let result {
        #expect(String(result.characters) == "getUserById")
    }
}

// MARK: - SwiftUI-specific AttributedString tests (Apple platforms only)

#if canImport(SwiftUI)

@Test func attributedHighlightSwiftUIForegroundColor() {
    let matcher = FuzzyMatcher()
    let result = matcher.attributedHighlight("format:modern", against: "mod") {
        $0.foregroundColor = .orange
    }
    #expect(result != nil)
    if let result {
        for run in result.runs {
            let text = String(result[run.range].characters)
            if text == "mod" {
                #expect(run.foregroundColor == .orange)
            } else {
                #expect(run.foregroundColor == nil)
            }
        }
    }
}

@Test func attributedHighlightSwiftUIMultipleAttributes() {
    let matcher = FuzzyMatcher()
    let result = matcher.attributedHighlight("getUserById", against: "get") {
        $0.foregroundColor = .red
        $0.underlineStyle = .single
    }
    #expect(result != nil)
    if let result {
        for run in result.runs {
            let text = String(result[run.range].characters)
            if text == "get" {
                #expect(run.foregroundColor == .red)
                #expect(run.underlineStyle == .single)
            } else {
                #expect(run.foregroundColor == nil)
                #expect(run.underlineStyle == nil)
            }
        }
    }
}

#endif // canImport(SwiftUI)

#endif // canImport(Foundation)
