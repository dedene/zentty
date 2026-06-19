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

// MARK: - MatchKind.description (0% → 100%)

@Test func matchKindExactDescription() {
    #expect(MatchKind.exact.description == "exact")
}

@Test func matchKindPrefixDescription() {
    #expect(MatchKind.prefix.description == "prefix")
}

@Test func matchKindSubstringDescription() {
    #expect(MatchKind.substring.description == "substring")
}

@Test func matchKindAcronymDescription() {
    #expect(MatchKind.acronym.description == "acronym")
}

@Test func matchKindAlignmentDescription() {
    #expect(MatchKind.alignment.description == "alignment")
}

// MARK: - ScoredMatch Comparable & CustomStringConvertible

@Test func scoredMatchLessThan() {
    let low = ScoredMatch(score: 0.4, kind: .substring)
    let high = ScoredMatch(score: 0.9, kind: .exact)
    #expect(low < high)
    #expect(!(high < low))
    #expect(!(low < low)) // swiftlint:disable:this identical_operands
}

@Test func scoredMatchDescription() {
    let match = ScoredMatch(score: 0.75, kind: .prefix)
    let desc = match.description
    #expect(desc.contains("0.75"))
    #expect(desc.contains("prefix"))
}

// MARK: - MatchResult Comparable & CustomStringConvertible

@Test func matchResultLessThan() {
    let low = MatchResult(candidate: "a", match: ScoredMatch(score: 0.3, kind: .substring))
    let high = MatchResult(candidate: "b", match: ScoredMatch(score: 0.8, kind: .exact))
    #expect(low < high)
    #expect(!(high < low))
}

@Test func matchResultDescription() {
    let result = MatchResult(candidate: "hello", match: ScoredMatch(score: 0.8, kind: .exact))
    let desc = result.description
    #expect(desc.contains("hello"))
    #expect(desc.contains("0.8"))
}

// MARK: - FuzzyQuery Equatable

@Test func fuzzyQueryEquatableSameQuery() {
    let matcher = FuzzyMatcher()
    let q1 = matcher.prepare("hello")
    let q2 = matcher.prepare("hello")
    #expect(q1 == q2)
}

@Test func fuzzyQueryEquatableDifferentQuery() {
    let matcher = FuzzyMatcher()
    let q1 = matcher.prepare("hello")
    let q2 = matcher.prepare("world")
    #expect(q1 != q2)
}

@Test func fuzzyQueryEquatableDifferentConfig() {
    let ed = FuzzyMatcher()
    let sw = FuzzyMatcher(config: .smithWaterman)
    let q1 = ed.prepare("hello")
    let q2 = sw.prepare("hello")
    #expect(q1 != q2)
}

// MARK: - MatchConfig accessors

@Test func matchConfigEditDistanceAccessor() {
    let config = MatchConfig.editDistance
    #expect(config.editDistanceConfig != nil)
    #expect(config.smithWatermanConfig == nil)
}

@Test func matchConfigSmithWatermanAccessor() {
    let config = MatchConfig.smithWaterman
    #expect(config.smithWatermanConfig != nil)
    #expect(config.editDistanceConfig == nil)
}

// MARK: - Debug descriptions

@Test func gapPenaltyDebugDescriptionNone() {
    #expect(GapPenalty.none.debugDescription == "GapPenalty.none")
}

@Test func gapPenaltyDebugDescriptionLinear() {
    let desc = GapPenalty.linear(perCharacter: 0.05).debugDescription
    #expect(desc.contains("linear"))
    #expect(desc.contains("0.05"))
}

@Test func gapPenaltyDebugDescriptionAffine() {
    let desc = GapPenalty.affine(open: 0.03, extend: 0.005).debugDescription
    #expect(desc.contains("affine"))
    #expect(desc.contains("0.03"))
    #expect(desc.contains("0.005"))
}

@Test func matchingAlgorithmDebugDescriptionEditDistance() {
    let desc = MatchingAlgorithm.editDistance(.default).debugDescription
    #expect(desc.contains("editDistance"))
}

@Test func matchingAlgorithmDebugDescriptionSmithWaterman() {
    let desc = MatchingAlgorithm.smithWaterman(.default).debugDescription
    #expect(desc.contains("smithWaterman"))
}

@Test func editDistanceConfigDebugDescription() {
    let desc = EditDistanceConfig.default.debugDescription
    #expect(desc.contains("EditDistanceConfig"))
    #expect(desc.contains("maxED"))
}

@Test func matchConfigDebugDescription() {
    let desc = MatchConfig.editDistance.debugDescription
    #expect(desc.contains("MatchConfig"))
    #expect(desc.contains("minScore"))
}

@Test func smithWatermanConfigDebugDescription() {
    let desc = SmithWatermanConfig.default.debugDescription
    #expect(desc.contains("SmithWatermanConfig"))
    #expect(desc.contains("match:"))
}

// MARK: - Codable error paths

@Test func matchingAlgorithmDecodingUnknownTypeThrows() throws {
    let json = Data(#"{"type":"unknown","config":{}}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(MatchingAlgorithm.self, from: json)
    }
}

@Test func gapPenaltyDecodingUnknownTypeThrows() throws {
    let json = Data(#"{"type":"unknown"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(GapPenalty.self, from: json)
    }
}

// MARK: - Convenience API string overloads

@Test func topMatchesStringQueryOverload() {
    let matcher = FuzzyMatcher()
    let results = matcher.topMatches(
        ["apple", "application", "banana", "appetizer"],
        against: "app",
        limit: 2
    )
    #expect(results.count == 2)
    #expect(results[0].match.score >= results[1].match.score)
}

@Test func matchesStringQueryOverload() {
    let matcher = FuzzyMatcher()
    let results = matcher.matches(
        ["apple", "application", "banana", "appetizer"],
        against: "app"
    )
    #expect(results.count >= 2)
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

// MARK: - Acronym matching for candidates >64 characters

@Test func acronymMatchCandidateLongerThan64Chars() {
    let matcher = FuzzyMatcher()
    // Build a candidate >64 chars with word boundaries past position 64
    let long = "International_Business_Machines_Corporation_Global_Technology_Services_Division_Unit"
    #expect(long.utf8.count > 64)
    let query = matcher.prepare("ibmcgtsd")
    var buffer = matcher.makeBuffer()
    let result = matcher.score(long, against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .acronym)
}

@Test func acronymMatchCandidateWithBoundariesBeyond64() {
    let matcher = FuzzyMatcher()
    // Candidate with many short words pushing boundaries past position 64
    // Each segment is 4 chars + underscore, so position 64 is within the 13th word
    let long = "Ab Cd Ef Gh Ij Kl Mn Op Qr St Uv Wx Yz Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj"
    #expect(long.utf8.count > 64, "Expected >64 bytes, got \(long.utf8.count)")
    let query = matcher.prepare("ace")
    var buffer = matcher.makeBuffer()
    let result = matcher.score(long, against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - Single-char query: endBound path (non-alnum after match)

@Test func singleCharQueryWordBoundaryWithNonAlnumFollower() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("x")
    var buffer = matcher.makeBuffer()
    // "x" at a word boundary where the next char is non-alphanumeric → endBound = true
    let result = matcher.score("foo-x!bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func singleCharQueryWordBoundaryAtEnd() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("x")
    var buffer = matcher.makeBuffer()
    // "x" at the very end of candidate → nextPos >= candidateLength → endBound = true
    let result = matcher.score("foo-x", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - isWordBoundaryInline: multi-byte lead byte paths

@Test func singleCharQueryAfterMultiByteLead() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()
    // "ü" is 0xC3 0xBC, followed by "a" — prev byte is continuation (0xBC ∈ 0x80..0xBF)
    // so prevIsAlnum includes continuation bytes, meaning it's NOT a word boundary
    let result = matcher.score("üa", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - Smith-Waterman: Latin-1 2-byte char processing

@Test func smithWatermanLatin1CandidateProcessing() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ber")
    var buffer = matcher.makeBuffer()
    // "über" contains 0xC3 0xBC (ü) — exercises the Latin-1 2-byte path in SW candidate prep
    // Query "ber" matches the tail of "über"
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanLatin1AtPositionZero() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ö")
    var buffer = matcher.makeBuffer()
    // "ö" at position 0 exercises the outIdx == 0 branch for 2-byte chars
    let result = matcher.score("ö", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
}

// MARK: - Smith-Waterman: inline bonus branches (whitespace, delimiter, camelCase, digit)

@Test func smithWatermanWhitespaceCharBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("b")
    var buffer = matcher.makeBuffer()
    // Space character in candidate exercises the currIsWhitespace branch
    // and also prevIsWhitespace → bonusBoundaryWhitespace for the next char
    let result = matcher.score("a b", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanDelimiterBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // "/" before "bar" exercises the delimiter bonus branch (prevByte == 0x2F)
    let result = matcher.score("foo/bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanColonDelimiterBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // ":" delimiter (0x3A)
    let result = matcher.score("foo:bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanSemicolonDelimiterBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // ";" delimiter (0x3B)
    let result = matcher.score("foo;bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanPipeDelimiterBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // "|" delimiter (0x7C)
    let result = matcher.score("foo|bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanCamelCaseBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // camelCase transition: lowercase → uppercase
    let result = matcher.score("fooBar", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanDigitTransitionBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("3x")
    var buffer = matcher.makeBuffer()
    // Digit after non-digit: "abc3x" exercises !prevIsDigit && currIsDigit
    let result = matcher.score("abc3x", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func smithWatermanNonAlnumBoundaryBonus() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bar")
    var buffer = matcher.makeBuffer()
    // "#" is non-alnum, non-whitespace, non-delimiter → falls to generic boundary bonus
    let result = matcher.score("foo#bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - Smith-Waterman: empty input guard

@Test func smithWatermanEmptyCandidate() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("test")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("", against: query, buffer: &buffer)
    #expect(result == nil)
}

// MARK: - Smith-Waterman: multi-atom maxScore guard

@Test func smithWatermanMultiAtomScoring() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    // Multi-word query — exercises the multi-atom path
    let query = matcher.prepare("foo bar")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("foo bar baz", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .alignment || result?.kind == .exact)
}

@Test func smithWatermanMultiAtomFailsWhenAtomMissing() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    // Multi-word query where one atom doesn't match → nil (AND semantics)
    let query = matcher.prepare("foo zzz")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("foo bar baz", against: query, buffer: &buffer)
    #expect(result == nil)
}

// MARK: - SmithWaterman DP: boundary bonus upgrade in consecutive path

@Test func smithWatermanBoundaryBonusUpgradeInConsecutiveMatch() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    // "getUserById" with query "user" — 'u' is at a word boundary (camelCase),
    // and the consecutive matches 's','e','r' should carry/upgrade the bonus
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("getUserById", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - SmithWaterman DP: gap score tracking for last query column

@Test func smithWatermanGapScoreLastColumn() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    // Query where the last character matches with a gap before it
    let query = matcher.prepare("az")
    var buffer = matcher.makeBuffer()
    // 'a' matches at start, gap through 'bcdef', 'z' matches at end
    let result = matcher.score("abcdefz", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - Buffer shrink: wordInitials and smithWatermanState paths

@Test func bufferShrinkWordInitials() {
    var buffer = ScoringBuffer()
    buffer.shrinkCheckInterval = 1

    // Grow wordInitials beyond 128
    buffer.wordInitials = [UInt8](repeating: 0, count: 200)
    #expect(buffer.wordInitials.count == 200)

    // Trigger shrink
    buffer.recordUsage(queryLength: 5, candidateLength: 20)

    // wordInitials should have shrunk to 32
    #expect(buffer.wordInitials.count == 32)
}

@Test func bufferShrinkSmithWatermanState() {
    var buffer = ScoringBuffer()
    buffer.shrinkCheckInterval = 1

    // Grow smithWatermanState capacity beyond threshold
    buffer.smithWatermanState = SmithWatermanState(maxQueryLength: 500)
    #expect(buffer.smithWatermanState.queryCapacity == 500)

    // Record small usage so highWaterQueryLength is small (5)
    // Threshold: queryCapacity (500) > highWaterQueryLength * 4 (5 * 4 = 20) → shrink
    buffer.recordUsage(queryLength: 5, candidateLength: 20)

    // Should have shrunk — new capacity is max(64, 5*2) = 64
    #expect(buffer.smithWatermanState.queryCapacity <= 64)
}

@Test func smithWatermanStateEnsureCapacityRealloc() {
    var state = SmithWatermanState(maxQueryLength: 4)
    #expect(state.queryCapacity == 4)

    // Force realloc by requesting larger capacity
    state.ensureCapacity(10)
    #expect(state.queryCapacity == 10)
    #expect(state.buffer.count == 10 * 3)
}

// MARK: - Prefilters: computeCharBitmask(UnsafeBufferPointer<UInt8>) overload

@Test func computeCharBitmaskSpanOverloadASCII() {
    // Exercise the Span-based computeCharBitmask through Smith-Waterman scoring
    // which uses it internally for candidate bitmask computation
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("abc")
    var buffer = matcher.makeBuffer()
    // This goes through the SW path which uses Span-based bitmask computation
    let result = matcher.score("abcdef", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func computeCharBitmaskSpanOverloadMultiByte() {
    // Exercise the multi-byte path in the Span-based computeCharBitmask
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ü")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - ScoringBonuses: gap-completion traceback and fallback paths

@Test func subsequenceWithGapAtEnd() {
    // Exercise the gap-completion traceback path in optimizeMatchPositions:
    // query characters match with gaps requiring the traceback to follow gap states
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("abz")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("abcdefghijklmnz", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func subsequenceWithLargeGap() {
    // Query chars spread widely in candidate to exercise traceback gap following
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("axz")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("abcdefghijklmnopqrstuvwxyz", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - ScoringBonuses: findSubsequencePositions fallback scan past searchLimit

@Test func findSubsequencePositionsFallbackScan() {
    // Exercise the fallback scan path in findSubsequencePositions where a match
    // is found beyond the initial look-ahead window
    let matcher = FuzzyMatcher(config: MatchConfig(minScore: 0.0))
    // Long candidate where later query chars must be found via the fallback scan
    let query = matcher.prepare("az")
    var buffer = matcher.makeBuffer()
    let result = matcher.score(
        "a" + String(repeating: "b", count: 20) + "z",
        against: query,
        buffer: &buffer
    )
    #expect(result != nil)
}

// MARK: - WordBoundary: isWordBoundaryFromPrev after-digit path

@Test func wordBoundaryAfterDigit() {
    let matcher = FuzzyMatcher()
    // "1bar" — digit-to-letter is a word boundary
    let query = matcher.prepare("ba")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("foo1bar", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - WordBoundary: isCamelCaseBoundary function

@Test func camelCaseBoundaryDetection() {
    // Exercise isCamelCaseBoundary indirectly through scoring
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bn")
    var buffer = matcher.makeBuffer()
    // "aBigName" — 'B' at position 1 is a camelCase boundary
    let result = matcher.score("aBigName", against: query, buffer: &buffer)
    #expect(result != nil)
}

@Test func camelCaseBoundaryAtEdges() {
    // isCamelCaseBoundary with index 0 or out of range should return false
    // Exercise through actual scoring
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("A")
    var buffer = matcher.makeBuffer()
    // "A" at position 0 — no predecessor, so not a camelCase boundary
    let result = matcher.score("Apple", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .prefix)
}
