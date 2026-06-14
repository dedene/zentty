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

// MARK: - Lookup Function Unit Tests

@Test func confusable2ByteToASCIIMappings() {
    // NBSP (U+00A0) → space
    #expect(confusable2ByteToASCII(lead: 0xC2, second: 0xA0) == 0x20)
    // Acute accent (U+00B4) → apostrophe
    #expect(confusable2ByteToASCII(lead: 0xC2, second: 0xB4) == 0x27)
    // Okina (U+02BB) → apostrophe
    #expect(confusable2ByteToASCII(lead: 0xCA, second: 0xBB) == 0x27)
    // Modifier apostrophe (U+02BC) → apostrophe
    #expect(confusable2ByteToASCII(lead: 0xCA, second: 0xBC) == 0x27)
    // Non-confusable 0xC2 byte → 0
    #expect(confusable2ByteToASCII(lead: 0xC2, second: 0x80) == 0)
    // Non-confusable 0xCA byte → 0
    #expect(confusable2ByteToASCII(lead: 0xCA, second: 0x80) == 0)
}

@Test func confusable3ByteToASCIIMappings() {
    // Left single quote (U+2018) → apostrophe
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x98) == 0x27)
    // Right single quote (U+2019) → apostrophe
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x99) == 0x27)
    // Left double quote (U+201C) → double quote
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x9C) == 0x22)
    // Right double quote (U+201D) → double quote
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x9D) == 0x22)
    // Hyphen (U+2010) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x90) == 0x2D)
    // Non-breaking hyphen (U+2011) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x91) == 0x2D)
    // Figure dash (U+2012) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x92) == 0x2D)
    // En dash (U+2013) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x93) == 0x2D)
    // Em dash (U+2014) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x94) == 0x2D)
    // Minus sign (U+2212) → hyphen-minus
    #expect(confusable3ByteToASCII(second: 0x88, third: 0x92) == 0x2D)
    // Non-confusable → 0
    #expect(confusable3ByteToASCII(second: 0x80, third: 0x80) == 0)
    #expect(confusable3ByteToASCII(second: 0x88, third: 0x80) == 0)
}

@Test func confusableASCIIToCanonicalMappings() {
    // Grave accent → apostrophe
    #expect(confusableASCIIToCanonical(0x60) == 0x27)
    // Normal apostrophe unchanged
    #expect(confusableASCIIToCanonical(0x27) == 0x27)
    // Other ASCII bytes unchanged
    #expect(confusableASCIIToCanonical(0x41) == 0x41)
    #expect(confusableASCIIToCanonical(0x20) == 0x20)
}

// MARK: - Apostrophe-like Confusables: Edit Distance Mode

@Test func curlyApostropheMatchesAsciiED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Bo's So")
    var buffer = matcher.makeBuffer()
    // Right single quote in candidate
    let result = matcher.score("Bo\u{2019}s Song", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func okinaMatchesApostropheED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Hawai'i")
    var buffer = matcher.makeBuffer()
    // Okina in candidate
    let result = matcher.score("Hawai\u{02BB}i", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func modifierApostropheMatchesAsciiED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it's")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{02BC}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func graveAccentMatchesApostropheED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it`s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it's", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func acuteAccentMatchesApostropheED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it's")
    var buffer = matcher.makeBuffer()
    // Acute accent (U+00B4) in candidate
    let result = matcher.score("it\u{00B4}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func leftSingleQuoteMatchesApostropheED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it's")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{2018}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Apostrophe-like Confusables: Smith-Waterman Mode

@Test func curlyApostropheMatchesAsciiSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("Bo's So")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Bo\u{2019}s Song", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func okinaMatchesApostropheSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("Hawai'i")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Hawai\u{02BB}i", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func modifierApostropheMatchesAsciiSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("it's")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{02BC}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func graveAccentMatchesApostropheSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("it`s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it's", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Double-quote Confusables

@Test func curlyDoubleQuotesMatchAsciiED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("say \"hi\"")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("say \u{201C}hi\u{201D}", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func curlyDoubleQuotesMatchAsciiSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("say \"hi\"")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("say \u{201C}hi\u{201D}", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Dash-like Confusables

@Test func enDashMatchesHyphenED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("well-known")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("well\u{2013}known", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func emDashMatchesHyphenED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("well-known")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("well\u{2014}known", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func minusSignMatchesHyphenED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("x-y")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("x\u{2212}y", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func enDashMatchesHyphenSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("well-known")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("well\u{2013}known", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func nonBreakingHyphenMatchesHyphenED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a-b")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("a\u{2011}b", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Space-like Confusables

@Test func nbspMatchesSpaceED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello world")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("hello\u{00A0}world", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func nbspMatchesSpaceSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("hello world")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("hello\u{00A0}world", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Self-match with Confusables

@Test func curlyQuoteSelfMatchED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it\u{2019}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{2019}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func curlyQuoteSelfMatchSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("it\u{2019}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{2019}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func enDashSelfMatchED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("well\u{2013}known")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("well\u{2013}known", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Cross-variant Matching

@Test func leftQuoteMatchesRightQuoteED() {
    let matcher = FuzzyMatcher()
    // Left curly quote in query, right curly quote in candidate
    let query = matcher.prepare("it\u{2018}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{2019}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func okinaMatchesCurlyQuoteED() {
    let matcher = FuzzyMatcher()
    // Okina in query, right curly quote in candidate
    let query = matcher.prepare("it\u{02BB}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it\u{2019}s", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func enDashMatchesEmDashED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a\u{2013}b")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("a\u{2014}b", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Reverse Direction (confusable query → ASCII candidate)

@Test func curlyQuoteQueryMatchesAsciiCandidateED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it\u{2019}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it's", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func curlyQuoteQueryMatchesAsciiCandidateSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("it\u{2019}s")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("it's", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func enDashQueryMatchesAsciiCandidateED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("well\u{2013}known")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("well-known", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Scenario Tests (music library use cases)

@Test func musicLibraryCurlyQuoteED() {
    // "Bo's So" (ASCII apostrophe) → "Bo\u{2019}s Song" (curly quote)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Bo's So")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Bo\u{2019}s Song", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func musicLibraryOkinaED() {
    // "'uli'uli" (ASCII apostrophe) → "ʻuliʻuli" (okina)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("'uli'uli")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("\u{02BB}uli\u{02BB}uli", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func musicLibraryOkinaSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("'uli'uli")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("\u{02BB}uli\u{02BB}uli", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func musicLibraryHawaiiED() {
    // "Hawai'i" (ASCII) → "Hawaiʻi" (okina)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Hawai'i")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Hawai\u{02BB}i", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Bitmask Prefilter Tests

@Test func bitmaskConfusableNotFalselyRejected() {
    // Candidate with curly quote should not be rejected by bitmask prefilter
    // when query has ASCII apostrophe (both map to 0 in bitmask, so no false rejection)
    let candidateBytes = Array("it\u{2019}s".utf8)
    let (candidateMask, _) = computeCharBitmaskWithASCIICheck(candidateBytes)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("it's")
    #expect(passesCharBitmask(queryMask: query.charBitmask, candidateMask: candidateMask, maxEditDistance: 0))
}

@Test func bitmaskEnDashNotFalselyRejected() {
    let candidateBytes = Array("well\u{2013}known".utf8)
    let (candidateMask, _) = computeCharBitmaskWithASCIICheck(candidateBytes)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("well-known")
    #expect(passesCharBitmask(queryMask: query.charBitmask, candidateMask: candidateMask, maxEditDistance: 0))
}

@Test func bitmaskNBSPNotFalselyRejected() {
    let candidateBytes = Array("hello\u{00A0}world".utf8)
    let (candidateMask, _) = computeCharBitmaskWithASCIICheck(candidateBytes)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("hello world")
    #expect(passesCharBitmask(queryMask: query.charBitmask, candidateMask: candidateMask, maxEditDistance: 0))
}

// MARK: - Boundary Bonus Parity Tests
//
// Verify that confusable punctuation produces identical boundary bonuses
// (and therefore identical scores) as the corresponding ASCII punctuation.

@Test func enDashBoundaryParityED() {
    // "well-known" with ASCII hyphen vs en-dash should score identically
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("wk")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("well-known", against: query, buffer: &buffer)
    let dashResult = matcher.score("well\u{2013}known", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(dashResult != nil)
    #expect(asciiResult!.score == dashResult!.score)
}

@Test func enDashBoundaryParitySW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("wk")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("well-known", against: query, buffer: &buffer)
    let dashResult = matcher.score("well\u{2013}known", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(dashResult != nil)
    #expect(asciiResult!.score == dashResult!.score)
}

@Test func nbspBoundaryParitySW() {
    // NBSP should produce the same whitespace boundary bonus as regular space
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("hw")
    var buffer = matcher.makeBuffer()
    let spaceResult = matcher.score("hello world", against: query, buffer: &buffer)
    let nbspResult = matcher.score("hello\u{00A0}world", against: query, buffer: &buffer)
    #expect(spaceResult != nil)
    #expect(nbspResult != nil)
    #expect(spaceResult!.score == nbspResult!.score)
}

@Test func curlyApostropheBoundaryParityED() {
    // Apostrophe creates a word boundary; curly quote should too
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ds")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("don't stop", against: query, buffer: &buffer)
    let curlyResult = matcher.score("don\u{2019}t stop", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(curlyResult != nil)
    #expect(asciiResult!.score == curlyResult!.score)
}

@Test func curlyApostropheBoundaryParitySW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("ds")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("don't stop", against: query, buffer: &buffer)
    let curlyResult = matcher.score("don\u{2019}t stop", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(curlyResult != nil)
    #expect(asciiResult!.score == curlyResult!.score)
}

// MARK: - Acronym Matching with Confusable Separators

@Test func acronymWithEnDashSeparatorED() {
    // "bms" → "Bristol–Myers Squibb" (en-dash) — acronym should work like "Bristol-Myers Squibb"
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    let dashResult = matcher.score("Bristol\u{2013}Myers Squibb", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(dashResult != nil)
    #expect(asciiResult!.score == dashResult!.score)
    #expect(asciiResult!.kind == dashResult!.kind)
}

@Test func acronymWithEmDashSeparatorED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    let dashResult = matcher.score("Bristol\u{2014}Myers Squibb", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(dashResult != nil)
    #expect(asciiResult!.score == dashResult!.score)
    #expect(asciiResult!.kind == dashResult!.kind)
}

@Test func acronymWithNBSPSeparatorED() {
    // Acronym with NBSP word separator should work like regular space
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("icag")
    var buffer = matcher.makeBuffer()
    let spaceResult = matcher.score("International Consolidated Airlines Group", against: query, buffer: &buffer)
    let nbspResult = matcher.score(
        "International\u{00A0}Consolidated\u{00A0}Airlines\u{00A0}Group", against: query, buffer: &buffer
    )
    #expect(spaceResult != nil)
    #expect(nbspResult != nil)
    #expect(spaceResult!.score == nbspResult!.score)
    #expect(spaceResult!.kind == nbspResult!.kind)
}

@Test func acronymWithEnDashSeparatorSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bms")
    var buffer = matcher.makeBuffer()
    let asciiResult = matcher.score("Bristol-Myers Squibb", against: query, buffer: &buffer)
    let dashResult = matcher.score("Bristol\u{2013}Myers Squibb", against: query, buffer: &buffer)
    #expect(asciiResult != nil)
    #expect(dashResult != nil)
    #expect(asciiResult!.score == dashResult!.score)
    #expect(asciiResult!.kind == dashResult!.kind)
}
