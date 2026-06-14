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

// MARK: - Word Boundary Detection Tests

@Test func isWordBoundaryAtStart() {
    let bytes = Array("getUserById".utf8)
    let result = isWordBoundary(at: 0, in: bytes)
    #expect(result)
}

@Test func isWordBoundaryAtCamelCaseTransition() {
    let bytes = Array("getUserById".utf8)
    // g e t U s e r B y I d
    // 0 1 2 3 4 5 6 7 8 9 10
    let result3 = isWordBoundary(at: 3, in: bytes)  // U in User
    let result7 = isWordBoundary(at: 7, in: bytes)  // B in By
    let result9 = isWordBoundary(at: 9, in: bytes)  // I in Id
    #expect(result3)
    #expect(result7)
    #expect(result9)
}

@Test func isWordBoundaryNotInMiddleOfWord() {
    let bytes = Array("getUserById".utf8)
    let result1 = isWordBoundary(at: 1, in: bytes)  // e in get
    let result2 = isWordBoundary(at: 2, in: bytes)  // t in get
    let result4 = isWordBoundary(at: 4, in: bytes)  // s in User
    let result5 = isWordBoundary(at: 5, in: bytes)  // e in User
    #expect(!result1)
    #expect(!result2)
    #expect(!result4)
    #expect(!result5)
}

@Test func isWordBoundaryAfterUnderscore() {
    let bytes = Array("get_user_by_id".utf8)
    // g e t _ u s e r _ b y  _  i  d
    // 0 1 2 3 4 5 6 7 8 9 10 11 12 13
    let result0 = isWordBoundary(at: 0, in: bytes)   // g (start)
    let result4 = isWordBoundary(at: 4, in: bytes)   // u after _
    let result9 = isWordBoundary(at: 9, in: bytes)   // b after _
    let result12 = isWordBoundary(at: 12, in: bytes)  // i after _
    #expect(result0)
    #expect(result4)
    #expect(result9)
    #expect(result12)
}

@Test func isWordBoundaryAfterDigit() {
    let bytes = Array("user2name".utf8)
    // u s e r 2 n a m e
    // 0 1 2 3 4 5 6 7 8
    let result0 = isWordBoundary(at: 0, in: bytes)  // u (start)
    let result5 = isWordBoundary(at: 5, in: bytes)  // n after 2
    let result4 = isWordBoundary(at: 4, in: bytes)  // 2 is not boundary
    #expect(result0)
    #expect(result5)
    #expect(!result4)
}

@Test func isWordBoundaryAfterDot() {
    let bytes = Array("foo.bar".utf8)
    // f o o . b a r
    // 0 1 2 3 4 5 6
    let result0 = isWordBoundary(at: 0, in: bytes)  // f (start)
    let result4 = isWordBoundary(at: 4, in: bytes)  // b after .
    #expect(result0)
    #expect(result4)
}

@Test func isWordBoundaryAfterDash() {
    let bytes = Array("foo-bar".utf8)
    let result0 = isWordBoundary(at: 0, in: bytes)  // f (start)
    let result4 = isWordBoundary(at: 4, in: bytes)  // b after -
    #expect(result0)
    #expect(result4)
}

@Test func isWordBoundaryOutOfBounds() {
    let bytes = Array("abc".utf8)
    let result3 = isWordBoundary(at: 3, in: bytes)
    let result10 = isWordBoundary(at: 10, in: bytes)
    #expect(!result3)
    #expect(!result10)
}

// MARK: - Boundary Mask Tests

@Test func computeBoundaryMaskSimple() {
    let bytes = Array("abc".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Only position 0 is a boundary
    #expect(mask == 0b1)
}

@Test func computeBoundaryMaskCamelCase() {
    let bytes = Array("getUserById".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Boundaries at: 0 (g), 3 (U), 7 (B), 9 (I)
    // Binary: 0b1010001001 = positions 0, 3, 7, 9
    #expect((mask & (1 << 0)) != 0)  // position 0
    #expect((mask & (1 << 3)) != 0)  // position 3
    #expect((mask & (1 << 7)) != 0)  // position 7
    #expect((mask & (1 << 9)) != 0)  // position 9

    // Non-boundaries
    #expect((mask & (1 << 1)) == 0)  // position 1
    #expect((mask & (1 << 2)) == 0)  // position 2
    #expect((mask & (1 << 4)) == 0)  // position 4
}

@Test func computeBoundaryMaskSnakeCase() {
    let bytes = Array("get_user_id".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // g e t _ u s e r _ i d
    // 0 1 2 3 4 5 6 7 8 9 10
    // Boundaries at: 0 (g), 4 (u), 9 (i)
    #expect((mask & (1 << 0)) != 0)
    #expect((mask & (1 << 4)) != 0)
    #expect((mask & (1 << 9)) != 0)
}

@Test func computeBoundaryMaskMixedStyle() {
    let bytes = Array("XMLParser2Test".utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // X M L P a r s e r 2  T  e  s  t
    // 0 1 2 3 4 5 6 7 8 9 10 11 12 13
    // Boundaries at: 0 (X), 10 (T after 2)
    // Note: In this implementation, uppercase after uppercase is NOT a boundary
    // But lowercase to uppercase IS a boundary
    #expect((mask & (1 << 0)) != 0)   // position 0 (start)
    #expect((mask & (1 << 10)) != 0)  // position 10 (T after 2)
}

@Test func computeBoundaryMaskEmpty() {
    let bytes: [UInt8] = []
    let mask = computeBoundaryMask(bytes: bytes)
    #expect(mask == 0)
}

@Test func computeBoundaryMaskLongString() {
    // Test that we handle strings longer than 64 characters
    // Pattern "abcDef" has boundaries at: 0 (a-start), 3 (D-camelCase) for first repetition
    // Subsequent repetitions only have 'D' as boundary because 'a' after 'f' is not a boundary
    let longString = String(repeating: "abcDef", count: 20) // 120 characters
    let bytes = Array(longString.utf8)
    let mask = computeBoundaryMask(bytes: bytes)
    // Should only compute first 64 positions
    #expect((mask & (1 << 0)) != 0)   // position 0 (start of string)
    #expect((mask & (1 << 3)) != 0)   // position 3 (D - camelCase)
    #expect((mask & (1 << 6)) == 0)   // position 6 (a after f - NOT a boundary)
    #expect((mask & (1 << 9)) != 0)   // position 9 (D - camelCase)
    #expect((mask & (1 << 15)) != 0)  // position 15 (D - camelCase)
    #expect((mask & (1 << 21)) != 0)  // position 21 (D - camelCase)
}
