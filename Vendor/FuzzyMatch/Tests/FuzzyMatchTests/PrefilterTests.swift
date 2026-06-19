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

// MARK: - Length Bounds Filter

@Test func lengthBoundsFilterExactLengthMatch() {
    #expect(passesLengthBounds(candidateLength: 5, queryLength: 5, maxEditDistance: 2))
}

@Test func lengthBoundsFilterCandidateShorterByMaxEditDistance() {
    // Candidate can be up to maxEditDistance shorter
    #expect(passesLengthBounds(candidateLength: 3, queryLength: 5, maxEditDistance: 2))
}

@Test func lengthBoundsFilterCandidateTooShort() {
    // Candidate is 3 characters shorter than allowed
    #expect(!passesLengthBounds(candidateLength: 2, queryLength: 5, maxEditDistance: 2))
}

@Test func lengthBoundsFilterCandidateLonger() {
    // Candidate can be much longer than query (for subsequence matching)
    #expect(passesLengthBounds(candidateLength: 15, queryLength: 5, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 100, queryLength: 5, maxEditDistance: 2))
}

@Test func lengthBoundsFilterCandidateTooLong() {
    // No upper limit - long candidates are allowed for subsequence matching
    // This test verifies the new behavior
    #expect(passesLengthBounds(candidateLength: 16, queryLength: 5, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 1_000, queryLength: 5, maxEditDistance: 2))
}

@Test func lengthBoundsFilterEmptyQuery() {
    // Empty query with maxEditDistance 2 allows candidates with length >= -2 (effectively >= 0)
    #expect(passesLengthBounds(candidateLength: 0, queryLength: 0, maxEditDistance: 2))
    // Any non-negative length is allowed since there's no upper limit
    #expect(passesLengthBounds(candidateLength: 1, queryLength: 0, maxEditDistance: 2))
}

@Test func lengthBoundsFilterSingleCharQuery() {
    // Query length 1 with maxEditDistance 2: candidate must be >= -1 (effectively >= 0)
    // No upper limit for subsequence matching
    #expect(passesLengthBounds(candidateLength: 0, queryLength: 1, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 1, queryLength: 1, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 3, queryLength: 1, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 4, queryLength: 1, maxEditDistance: 2))
    #expect(passesLengthBounds(candidateLength: 100, queryLength: 1, maxEditDistance: 2))
}

// MARK: - Character Bitmask Computation

@Test func charBitmaskLowercaseLetters() {
    let bytes: [UInt8] = Array("abc".utf8)
    let mask = computeCharBitmask(bytes)

    // 'a' is bit 0, 'b' is bit 1, 'c' is bit 2
    #expect(mask == 0b111)
}

@Test func charBitmaskUppercaseLettersMapsToSameBitsAsLowercase() {
    // The lookup table maps both A-Z and a-z to the same bits 0-25.
    // computeCharBitmask expects lowercased input, but uppercase mapping
    // is harmless and makes the table usable for case-insensitive paths.
    let upper: [UInt8] = [0x41, 0x42, 0x43] // "ABC"
    let lower: [UInt8] = [0x61, 0x62, 0x63] // "abc"
    #expect(computeCharBitmask(upper) == computeCharBitmask(lower))
}

@Test func charBitmaskDigits() {
    let bytes: [UInt8] = Array("012".utf8)
    let mask = computeCharBitmask(bytes)

    // '0' is bit 26, '1' is bit 27, '2' is bit 28
    let expectedMask: UInt64 = (1 << 26) | (1 << 27) | (1 << 28)
    #expect(mask == expectedMask)
}

@Test func charBitmaskUnderscore() {
    let bytes: [UInt8] = Array("_".utf8)
    let mask = computeCharBitmask(bytes)

    // '_' is bit 36
    #expect(mask == (1 << 36))
}

@Test func charBitmaskMixedCharacters() {
    let bytes: [UInt8] = Array("a1_".utf8)
    let mask = computeCharBitmask(bytes)

    // 'a' is bit 0, '1' is bit 27, '_' is bit 36
    let expectedMask: UInt64 = (1 << 0) | (1 << 27) | (1 << 36)
    #expect(mask == expectedMask)
}

@Test func charBitmaskDuplicateCharacters() {
    // Duplicate characters should result in same mask
    let bytes1: [UInt8] = Array("aaa".utf8)
    let bytes2: [UInt8] = Array("a".utf8)

    #expect(computeCharBitmask(bytes1) == computeCharBitmask(bytes2))
}

@Test func charBitmaskEmptyInput() {
    let bytes: [UInt8] = []
    let mask = computeCharBitmask(bytes)

    #expect(mask == 0)
}

@Test func charBitmaskAllLowercaseLetters() {
    let bytes: [UInt8] = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    let mask = computeCharBitmask(bytes)

    // Bits 0-25 should all be set
    let expectedMask: UInt64 = (1 << 26) - 1
    #expect(mask == expectedMask)
}

@Test func charBitmaskAllDigits() {
    let bytes: [UInt8] = Array("0123456789".utf8)
    let mask = computeCharBitmask(bytes)

    // Bits 26-35 should all be set
    let expectedMask: UInt64 = ((1 << 10) - 1) << 26
    #expect(mask == expectedMask)
}

@Test func charBitmaskNonMappedCharacters() {
    // Characters that don't map (space, punctuation) should be ignored
    let bytes: [UInt8] = Array(" !@#$%^&*()".utf8)
    let mask = computeCharBitmask(bytes)

    #expect(mask == 0)
}

// MARK: - Bitmask Filter Correctness
// The bitmask filter checks that the number of distinct missing character types
// is within the edit budget (popcount(queryMask & ~candidateMask) <= maxEditDistance).
// Tests below use the default maxEditDistance=0 (strict mode) unless noted otherwise.

@Test func bitmaskFilterExactMatch() {
    let queryMask: UInt64 = 0b111 // abc
    let candidateMask: UInt64 = 0b111 // abc

    #expect(passesCharBitmask(queryMask: queryMask, candidateMask: candidateMask))
}

@Test func bitmaskFilterCandidateHasMoreCharacters() {
    let queryMask: UInt64 = 0b111 // abc
    let candidateMask: UInt64 = 0b1111 // abcd

    // All query chars (a,b,c) exist in candidate - passes
    #expect(passesCharBitmask(queryMask: queryMask, candidateMask: candidateMask))
}

@Test func bitmaskFilterQueryHasMissingCharacter() {
    let queryMask: UInt64 = 0b1111 // abcd
    let candidateMask: UInt64 = 0b111 // abc

    // 'd' in query not in candidate - FAILS (strict matching)
    #expect(!passesCharBitmask(queryMask: queryMask, candidateMask: candidateMask))
}

@Test func bitmaskFilterManyMissingCharacters() {
    let queryMask: UInt64 = 0b1111111 // abcdefg (7 chars)
    let candidateMask: UInt64 = 0b111 // abc (3 chars)

    // 4 characters in query not in candidate - fails
    #expect(!passesCharBitmask(queryMask: queryMask, candidateMask: candidateMask))
}

@Test func bitmaskFilterTranspositionSameChars() {
    // "test" and "tset" (transposition) have same characters
    let testMask = computeCharBitmask(Array("test".utf8))
    let tsetMask = computeCharBitmask(Array("tset".utf8))

    // Same characters, just different order - passes
    #expect(testMask == tsetMask)
    #expect(passesCharBitmask(queryMask: testMask, candidateMask: tsetMask))
}

@Test func bitmaskFilterSubstringMatch() {
    // "usr" matching "user" - all query chars exist
    let usrMask = computeCharBitmask(Array("usr".utf8))
    let userMask = computeCharBitmask(Array("user".utf8))

    #expect(passesCharBitmask(queryMask: usrMask, candidateMask: userMask))
}

@Test func bitmaskFilterAbbreviationMatch() {
    // "gubi" matching "getUserById" - all query chars exist
    let gubiMask = computeCharBitmask(Array("gubi".utf8))
    let getUserByIdMask = computeCharBitmask(Array("getuserbyid".utf8))

    #expect(passesCharBitmask(queryMask: gubiMask, candidateMask: getUserByIdMask))
}

@Test func bitmaskFilterRejectsMissingChar() {
    // "gubi" should NOT match "buildApiXml" - 'g' is missing from candidate
    let gubiMask = computeCharBitmask(Array("gubi".utf8))
    let buildMask = computeCharBitmask(Array("buildapixml".utf8))

    // 'g' is in query but not in candidate - fails
    #expect(!passesCharBitmask(queryMask: gubiMask, candidateMask: buildMask))
}

// MARK: - lowercaseASCII Function

@Test func lowercaseASCIIUppercaseLetters() {
    #expect(lowercaseASCII(0x41) == 0x61) // A -> a
    #expect(lowercaseASCII(0x5A) == 0x7A) // Z -> z
    #expect(lowercaseASCII(0x4D) == 0x6D) // M -> m
}

@Test func lowercaseASCIILowercaseUnchanged() {
    #expect(lowercaseASCII(0x61) == 0x61) // a -> a
    #expect(lowercaseASCII(0x7A) == 0x7A) // z -> z
    #expect(lowercaseASCII(0x6D) == 0x6D) // m -> m
}

@Test func lowercaseASCIIDigitsUnchanged() {
    for digit: UInt8 in 0x30...0x39 { // '0' to '9'
        #expect(lowercaseASCII(digit) == digit)
    }
}

@Test func lowercaseASCIISpecialCharactersUnchanged() {
    #expect(lowercaseASCII(0x20) == 0x20) // space
    #expect(lowercaseASCII(0x5F) == 0x5F) // underscore
    #expect(lowercaseASCII(0x2D) == 0x2D) // hyphen
    #expect(lowercaseASCII(0x2E) == 0x2E) // period
}

@Test func lowercaseASCIIBoundaryValues() {
    // Just before 'A' (0x40 = '@')
    #expect(lowercaseASCII(0x40) == 0x40)
    // Just after 'Z' (0x5B = '[')
    #expect(lowercaseASCII(0x5B) == 0x5B)
}

@Test func lowercaseASCIINonASCIIPassThrough() {
    // Non-ASCII bytes should pass through unchanged
    #expect(lowercaseASCII(0x80) == 0x80)
    #expect(lowercaseASCII(0xFF) == 0xFF)
    #expect(lowercaseASCII(0xC0) == 0xC0)
}

// MARK: - Latin Extended Case Folding

@Test func lowercaseLatinExtendedAGrave() {
    // U+00C0 (À) second byte is 0x80, should fold to 0xA0 (à)
    #expect(lowercaseLatinExtended(0x80) == 0xA0)
}

@Test func lowercaseLatinExtendedNTilde() {
    // U+00D1 (Ñ) second byte is 0x91, should fold to 0xB1 (ñ)
    #expect(lowercaseLatinExtended(0x91) == 0xB1)
}

@Test func lowercaseLatinExtendedMultiplicationSign() {
    // U+00D7 (×) second byte is 0x97, should NOT be folded (not a letter)
    #expect(lowercaseLatinExtended(0x97) == 0x97)
}

@Test func lowercaseLatinExtendedThorn() {
    // U+00DE (Þ) second byte is 0x9E, should fold to 0xBE (þ)
    #expect(lowercaseLatinExtended(0x9E) == 0xBE)
}

@Test func lowercaseLatinExtendedAlreadyLowercase() {
    // U+00E0 (à) second byte is 0xA0, should not be changed
    #expect(lowercaseLatinExtended(0xA0) == 0xA0)
}

@Test func isLatinExtendedLeadByte() {
    #expect(isLatinExtendedLead(0xC3))
    #expect(!isLatinExtendedLead(0xC4))
    #expect(!isLatinExtendedLead(0x41))
}

@Test func latinExtendedCaseFoldingInMatcher() {
    // Test that FuzzyMatcher handles Latin-1 case folding correctly
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // "societe" should match "Société" (with uppercase S and accented e)
    // Note: é (U+00E9) is already lowercase, but S/s is ASCII
    let query = matcher.prepare("societe")
    let result = matcher.score("Societe", against: query, buffer: &buffer)
    #expect(result != nil)

    // Lowercase query with accented uppercase candidate
    let query2 = matcher.prepare("à")
    let result2 = matcher.score("À", against: query2, buffer: &buffer)
    #expect(result2 != nil)
    #expect(result2?.score == 1.0) // Should be exact match after case folding
}

@Test func latinExtendedWordBoundaryNotTriggered() {
    // Accented characters should not trigger word boundaries incorrectly
    let bytes = Array("Société".utf8)
    // The é is a 2-byte sequence 0xC3 0xA9, should not trigger boundary
    let mask = computeBoundaryMask(bytes: bytes)
    // Position 0 is always a boundary
    #expect((mask & 1) != 0)
}

// MARK: - German Characters

@Test func germanUmlautCaseFolding() {
    // Ä (U+00C4) → ä (U+00E4), Ö (U+00D6) → ö (U+00F6), Ü (U+00DC) → ü (U+00FC)
    // UTF-8: 0xC3 0x84 → 0xC3 0xA4, 0xC3 0x96 → 0xC3 0xB6, 0xC3 0x9C → 0xC3 0xBC
    #expect(lowercaseLatinExtended(0x84) == 0xA4) // Ä → ä
    #expect(lowercaseLatinExtended(0x96) == 0xB6) // Ö → ö
    #expect(lowercaseLatinExtended(0x9C) == 0xBC) // Ü → ü
}

@Test func germanEszettNotFolded() {
    // ß (U+00DF) is lowercase-only in Latin-1, second byte 0x9F
    // Should not be changed (it's at the boundary between upper and lower range)
    #expect(lowercaseLatinExtended(0x9F) == 0x9F)
}

@Test func germanUmlautMatcherCaseInsensitive() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Lowercase query should match uppercase candidate umlauts
    let query = matcher.prepare("ärger")
    let result = matcher.score("Ärger", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func germanUmlautExactMatch() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("über")
    let result = matcher.score("über", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func germanCompanyNameFuzzyMatch() {
    // Realistic: searching for a German company/instrument name
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("münchener")
    let result = matcher.score("Münchener Rück", against: query, buffer: &buffer)
    #expect(result != nil)

    // Uppercase query should also match
    let query2 = matcher.prepare("MÜNCHENER")
    let result2 = matcher.score("Münchener Rück", against: query2, buffer: &buffer)
    #expect(result2 != nil)
}

@Test func germanEszettInCandidate() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // ß should match itself (no case folding needed — only lowercase form exists in Latin-1)
    let query = matcher.prepare("straße")
    let result = matcher.score("Straße", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

// MARK: - Swedish Characters

@Test func swedishAringCaseFolding() {
    // Å (U+00C5) → å (U+00E5)
    // UTF-8: 0xC3 0x85 → 0xC3 0xA5
    #expect(lowercaseLatinExtended(0x85) == 0xA5) // Å → å
}

@Test func swedishCharactersCaseFolding() {
    // Swedish uses Ä/ä and Ö/ö (shared with German) plus Å/å
    // Verify all three pairs
    #expect(lowercaseLatinExtended(0x85) == 0xA5) // Å → å
    #expect(lowercaseLatinExtended(0x84) == 0xA4) // Ä → ä
    #expect(lowercaseLatinExtended(0x96) == 0xB6) // Ö → ö
}

@Test func swedishAringMatcherCaseInsensitive() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("åland")
    let result = matcher.score("Åland", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result?.score == 1.0)
}

@Test func swedishCompanyNameFuzzyMatch() {
    // Realistic: Swedish company/instrument name
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    let query = matcher.prepare("ericsson")
    let result = matcher.score("Telefonaktiebolaget LM Ericsson", against: query, buffer: &buffer)
    #expect(result != nil)

    // Name with Swedish characters
    let query2 = matcher.prepare("björk")
    let result2 = matcher.score("Björk Invest AB", against: query2, buffer: &buffer)
    #expect(result2 != nil)
}

@Test func swedishMixedUmlautsInQuery() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Query containing all three Swedish special characters
    let query = matcher.prepare("åäö")
    let result = matcher.score("Åäö Test", against: query, buffer: &buffer)
    #expect(result != nil)
}
