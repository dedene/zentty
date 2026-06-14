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

// MARK: - Latin-1 Diacritic Normalization: Edit Distance Mode

@Test func uberMatchesUeberED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("uber")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func cafeMatchesCafeED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("cafe")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("café", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func resumeMatchesResumeED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("resume")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("résumé", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func angstromMatchesAngstromED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("angstrom")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Ångström", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func naiiveMatchesNaiveED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("naive")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("naïve", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Latin-1 Diacritic Normalization: Smith-Waterman Mode

@Test func uberMatchesUeberSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("uber")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func cafeMatchesCafeSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("cafe")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("café", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func resumeMatchesResumeSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("resume")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("résumé", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Self-match with diacritics

@Test func ueberSelfMatchED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("über")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func ueberSelfMatchSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("über")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Diacritic query matches ASCII candidate

@Test func ueberQueryMatchesAsciiUberED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("über")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("uber", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func ueberQueryMatchesAsciiUberSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("über")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("uber", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Non-diacritic Latin-1 chars remain distinct

@Test func aeRemainsDistinct() {
    // æ (ligature) should NOT normalize to 'a' or 'ae'
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("æ", against: query, buffer: &buffer)
    // æ is not normalized to 'a', so single-char ASCII 'a' won't match 2-byte æ
    #expect(result == nil)
}

@Test func ethRemainsDistinct() {
    // ð (eth) should NOT normalize to 'd'
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("d")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("ð", against: query, buffer: &buffer)
    #expect(result == nil)
}

@Test func thornRemainsDistinct() {
    // þ (thorn) should NOT normalize to 't'
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("t")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("þ", against: query, buffer: &buffer)
    #expect(result == nil)
}

@Test func slashedORemainsDistinct() {
    // ø (slashed o) should NOT normalize to 'o'
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("o")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("ø", against: query, buffer: &buffer)
    #expect(result == nil)
}

// MARK: - latin1ToASCII unit tests

@Test func latin1ToASCIIMappings() {
    // Verify all expected mappings
    #expect(latin1ToASCII(0xA0) == 0x61)  // à → a
    #expect(latin1ToASCII(0xA1) == 0x61)  // á → a
    #expect(latin1ToASCII(0xA2) == 0x61)  // â → a
    #expect(latin1ToASCII(0xA3) == 0x61)  // ã → a
    #expect(latin1ToASCII(0xA4) == 0x61)  // ä → a
    #expect(latin1ToASCII(0xA5) == 0x61)  // å → a
    #expect(latin1ToASCII(0xA6) == 0)     // æ → no mapping
    #expect(latin1ToASCII(0xA7) == 0x63)  // ç → c
    #expect(latin1ToASCII(0xA8) == 0x65)  // è → e
    #expect(latin1ToASCII(0xA9) == 0x65)  // é → e
    #expect(latin1ToASCII(0xAA) == 0x65)  // ê → e
    #expect(latin1ToASCII(0xAB) == 0x65)  // ë → e
    #expect(latin1ToASCII(0xAC) == 0x69)  // ì → i
    #expect(latin1ToASCII(0xAD) == 0x69)  // í → i
    #expect(latin1ToASCII(0xAE) == 0x69)  // î → i
    #expect(latin1ToASCII(0xAF) == 0x69)  // ï → i
    #expect(latin1ToASCII(0xB0) == 0)     // ð → no mapping
    #expect(latin1ToASCII(0xB1) == 0x6E)  // ñ → n
    #expect(latin1ToASCII(0xB2) == 0x6F)  // ò → o
    #expect(latin1ToASCII(0xB3) == 0x6F)  // ó → o
    #expect(latin1ToASCII(0xB4) == 0x6F)  // ô → o
    #expect(latin1ToASCII(0xB5) == 0x6F)  // õ → o
    #expect(latin1ToASCII(0xB6) == 0x6F)  // ö → o
    #expect(latin1ToASCII(0xB7) == 0)     // ÷ → no mapping
    #expect(latin1ToASCII(0xB8) == 0)     // ø → no mapping
    #expect(latin1ToASCII(0xB9) == 0x75)  // ù → u
    #expect(latin1ToASCII(0xBA) == 0x75)  // ú → u
    #expect(latin1ToASCII(0xBB) == 0x75)  // û → u
    #expect(latin1ToASCII(0xBC) == 0x75)  // ü → u
    #expect(latin1ToASCII(0xBD) == 0x79)  // ý → y
    #expect(latin1ToASCII(0xBE) == 0)     // þ → no mapping
    #expect(latin1ToASCII(0xBF) == 0x79)  // ÿ → y
}

// MARK: - Bitmask prefilter with diacritics

@Test func bitmaskUeberMatchesUber() {
    // "über" candidate should have 'u' bit set (not just multi-byte bit)
    let uberBytes = Array("über".utf8)
    let (mask, _) = computeCharBitmaskWithASCIICheck(uberBytes)
    // 'u' is bit 20 (0x75 - 0x61 = 20)
    let uBit: UInt64 = 1 << 20
    #expect(mask & uBit != 0, "über should have 'u' bit set in bitmask")
}

@Test func bitmaskCafeMatchesCafe() {
    let cafeBytes = Array("café".utf8)
    let (mask, _) = computeCharBitmaskWithASCIICheck(cafeBytes)
    // 'e' is bit 4 (0x65 - 0x61 = 4)
    let eBit: UInt64 = 1 << 4
    #expect(mask & eBit != 0, "café should have 'e' bit set in bitmask")
}

// MARK: - Compound diacritics in longer candidates

@Test func diacriticInLongerCandidateED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("uber")
    var buffer = matcher.makeBuffer()
    // "über technologies" should match "uber" as prefix/substring
    let result = matcher.score("Über Technologies", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)
}

@Test func diacriticInLongerCandidateSW() {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("uber")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Über Technologies", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)
}

// MARK: - Multiple diacritics in one word

@Test func multipleDiacriticsED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("noel")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("Noël", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func allVowelDiacriticsED() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("aeiou")
    var buffer = matcher.makeBuffer()
    let result = matcher.score("àéîõü", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}
