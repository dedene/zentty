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

// MARK: - Cyrillic Case Folding Tests

@Test func cyrillicExactMatchCaseInsensitive() {
    // "БЕОГРАД" should match "београд" exactly (score 1.0)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("БЕОГРАД")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("београд", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func cyrillicPrefixMatch() {
    // "беог" should match "београд" as prefix
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("беог")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("београд", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func cyrillicUppercasePrefixMatch() {
    // "БЕОГ" should match "београд" as prefix (case-insensitive)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("БЕОГ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("београд", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func cyrillicCrossLeadByte() {
    // "С" (D0 A1) lowercases to "с" (D1 81) — crosses lead byte boundary
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("СРБИЈА")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("србија", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func cyrillicDjeFolding() {
    // "Ђ" (D0 82) lowercases to "ђ" (D1 92) — Serbian letter, crosses lead byte
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ЂЕРДАП")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("ђердап", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func cyrillicMixedCaseExact() {
    // Mixed case Cyrillic should match lowercased exactly
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("Београд")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("београд", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

// MARK: - Greek Case Folding Tests

@Test func greekExactMatchCaseInsensitive() {
    // "ΑΘΗΝΑ" should match "αθηνα" exactly
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ΑΘΗΝΑ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("αθηνα", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func greekCrossLeadByte() {
    // "Π" (CE A0) lowercases to "π" (CF 80) — crosses lead byte boundary
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ΠΑΤΡΑ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("πατρα", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func greekSigmaFolding() {
    // "ΣΙΓΜΑ" should match "σιγμα" — Σ (CE A3) → σ (CF 83)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ΣΙΓΜΑ")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("σιγμα", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}

@Test func greekPrefixMatch() {
    // "αθη" should match "αθηνα" as prefix
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("αθη")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("αθηνα", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

// MARK: - Bitmask Prefilter Tests

@Test func cyrillicBitmaskNonZero() {
    // Cyrillic characters should produce non-zero bitmask bits
    let bytes = Array("београд".utf8)
    let mask = computeCharBitmask(bytes)
    #expect(mask != 0)
}

@Test func greekBitmaskNonZero() {
    // Greek characters should produce non-zero bitmask bits
    let bytes = Array("αθηνα".utf8)
    let mask = computeCharBitmask(bytes)
    #expect(mask != 0)
}

@Test func cyrillicBitmaskCaseInsensitiveMatch() {
    // Upper and lowercase Cyrillic should produce matching bitmasks
    let upper = Array("БЕОГРАД".utf8)
    let lower = Array("београд".utf8)
    let upperMask = computeCharBitmaskCaseInsensitive(upper)
    let lowerMask = computeCharBitmaskCaseInsensitive(lower)
    #expect(upperMask == lowerMask)
}

@Test func greekBitmaskCaseInsensitiveMatch() {
    // Upper and lowercase Greek should produce matching bitmasks
    let upper = Array("ΑΘΗΝΑ".utf8)
    let lower = Array("αθηνα".utf8)
    let upperMask = computeCharBitmaskCaseInsensitive(upper)
    let lowerMask = computeCharBitmaskCaseInsensitive(lower)
    #expect(upperMask == lowerMask)
}

// MARK: - Word Boundary Tests

@Test func cyrillicNoFalseBoundaries() {
    // No false word boundaries inside a Cyrillic word
    let bytes = Array("београд".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Only position 0 should be a boundary
    #expect(mask == 1)
}

@Test func greekNoFalseBoundaries() {
    // No false word boundaries inside a Greek word
    let bytes = Array("αθηνα".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Only position 0 should be a boundary
    #expect(mask == 1)
}

@Test func cyrillicMultiWordBoundaries() {
    // Space-separated Cyrillic words should have boundaries at word starts
    let text = "нови сад"
    let bytes = Array(text.utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Boundary at position 0 and after the space
    #expect((mask & 1) != 0)  // position 0
    let spacePos = Array("нови ".utf8).count
    #expect((mask & (1 << spacePos)) != 0)  // after space
}

// MARK: - Mixed Script Tests

@Test func mixedLatinCyrillicNoFalseMatch() {
    // Latin "a" should not match Cyrillic "а" (they look similar but are different bytes)
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    var buffer = matcher.makeBuffer()

    // Cyrillic "а" is D0 B0, not ASCII 0x61
    let result = matcher.score("а", against: query, buffer: &buffer)
    // The single-char query "a" (ASCII) should not match Cyrillic "а" (D0 B0)
    #expect(result == nil)
}

@Test func cyrillicSingleChar() {
    // Single Cyrillic character query (2 bytes) goes through full pipeline
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("б")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("београд", against: query, buffer: &buffer)
    #expect(result != nil)
}

// MARK: - Acronym Tests

@Test func cyrillicAcronymMatch() {
    // Cyrillic multi-word name with word-initial matching.
    // "нбс" matches "народна" as prefix (higher score), so we just check it matches.
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("нбс")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("народна библиотека србије", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)
}

@Test func greekMultiWordSubsequence() {
    // Greek multi-word candidate — verify subsequence matching works
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("κοινο")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("ελληνικό κοινοβούλιο πολιτών", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)
}

// MARK: - Latin-1 Regression Tests

@Test func latinExtendedStillWorks() {
    // Verify Latin-1 Supplement case folding still works after changes
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("ÜBER")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.5)
}

@Test func latinExtendedExactMatch() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("café")
    var buffer = matcher.makeBuffer()

    let result = matcher.score("café", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result!.score == 1.0)
}
