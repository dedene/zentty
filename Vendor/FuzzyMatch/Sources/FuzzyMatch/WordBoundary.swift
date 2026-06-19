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

/// Word boundary detection for scoring bonuses.
///
/// Word boundaries identify positions in code identifiers where new "words" begin.
/// Matching query characters at word boundaries is rewarded with a scoring bonus,
/// as it indicates the user is likely typing abbreviations of multi-word identifiers.
///
/// ## Overview
///
/// Word boundaries occur at:
/// - Start of string (position 0)
/// - After underscore: `get_user` -> positions 0, 4
/// - Lowercase to uppercase transition (camelCase): `getUserById` -> positions 0, 3, 7, 9
/// - After digit: `user2name` -> positions 0, 5
/// - After non-alphanumeric: `foo.bar` -> positions 0, 4
///
/// ## Example
///
/// ```swift
/// // "getUserById" has word boundaries at:
/// // g e t U s e r B y I d
/// // ^     ^       ^   ^
/// // 0     3       7   9
///
/// let bytes = Array("getUserById".utf8)
/// let mask = bytes.withUnsafeBufferPointer { computeBoundaryMask(bytes: $0) }
/// // mask has bits set at positions 0, 3, 7, 9
/// ```

/// Checks if a position is a word boundary in a byte sequence.
///
/// Word boundaries are detected using these rules:
/// - Position 0 is always a boundary (start of identifier)
/// - After `_` (underscore): `snake_case` -> boundary at position after `_`
/// - Lowercase to uppercase: `camelCase` -> boundary at uppercase letter
/// - After digit: `name2value` -> boundary after the digit
/// - After non-alphanumeric: `foo.bar` -> boundary after `.`
///
/// - Parameters:
///   - index: The position to check (0-based).
///   - bytes: The UTF-8 byte buffer to examine.
/// - Returns: `true` if the position is a word boundary.
///
/// ## Complexity
///
/// O(1) - constant time comparison.
///
/// ## Example
///
/// ```swift
/// let bytes = Array("getUserById".utf8)
/// bytes.withUnsafeBufferPointer { ptr in
///     isWordBoundary(at: 0, in: ptr)  // true (start)
///     isWordBoundary(at: 1, in: ptr)  // false (middle of "get")
///     isWordBoundary(at: 3, in: ptr)  // true (U in User)
///     isWordBoundary(at: 7, in: ptr)  // true (B in By)
/// }
/// ```
@inlinable
internal func isWordBoundary(
    at index: Int,
    in bytes: UnsafeBufferPointer<UInt8>
) -> Bool {
    let length = bytes.count
    // Position 0 is always a boundary
    if index == 0 { return true }
    if index >= length { return false }

    let current = bytes[index]
    let previous = bytes[index - 1]

    // After underscore
    if previous == 0x5F { return true }  // '_'

    // After digit (0-9)
    if previous >= 0x30 && previous <= 0x39 { return true }

    // Lowercase to uppercase transition (camelCase)
    let prevIsLower = (previous >= 0x61 && previous <= 0x7A)
    let currIsUpper = (current >= 0x41 && current <= 0x5A)
    if prevIsLower && currIsUpper { return true }

    // After non-alphanumeric (dots, dashes, etc.)
    // Treat the lead byte 0xC3 (Latin-1 Supplement) as alphanumeric since it's part
    // of a multi-byte letter sequence. The continuation byte (0x80-0xBF) is also
    // treated as part of the letter and not a boundary trigger.
    let prevIsAlnum = (previous >= 0x30 && previous <= 0x39) ||
                      (previous >= 0x41 && previous <= 0x5A) ||
                      (previous >= 0x61 && previous <= 0x7A) ||
                      previous == 0xC3 ||                        // Latin-1 lead
                      previous == 0xCE || previous == 0xCF ||    // Greek lead
                      previous == 0xD0 || previous == 0xD1 ||    // Cyrillic lead
                      (previous >= 0x80 && previous <= 0xBF)     // continuation byte
    if !prevIsAlnum { return true }

    return false
}

/// Checks if a byte pair constitutes a word boundary given an explicit previous byte.
///
/// This is equivalent to ``isWordBoundary(at:in:)`` but takes the previous byte
/// directly instead of reading it from a buffer. Used by ``computeBoundaryMaskCompressed``
/// where combining marks are skipped and the true predecessor may not be adjacent
/// in the original byte buffer.
///
/// - Parameters:
///   - prev: The previous meaningful byte (after skipping combining marks).
///   - current: The current byte to check.
/// - Returns: `true` if the transition from `prev` to `current` is a word boundary.
@inlinable
internal func isWordBoundaryFromPrev(prev: UInt8, current: UInt8) -> Bool {
    // After underscore
    if prev == 0x5F { return true }  // '_'

    // After digit (0-9)
    if prev >= 0x30 && prev <= 0x39 { return true }

    // Lowercase to uppercase transition (camelCase)
    let prevIsLower = (prev >= 0x61 && prev <= 0x7A)
    let currIsUpper = (current >= 0x41 && current <= 0x5A)
    if prevIsLower && currIsUpper { return true }

    // After non-alphanumeric (dots, dashes, etc.)
    let prevIsAlnum = (prev >= 0x30 && prev <= 0x39) ||
                      (prev >= 0x41 && prev <= 0x5A) ||
                      (prev >= 0x61 && prev <= 0x7A) ||
                      prev == 0xC3 ||                        // Latin-1 lead
                      prev == 0xCE || prev == 0xCF ||        // Greek lead
                      prev == 0xD0 || prev == 0xD1 ||        // Cyrillic lead
                      (prev >= 0x80 && prev <= 0xBF)         // continuation byte
    if !prevIsAlnum { return true }

    return false
}

/// Checks if a position is a camelCase boundary (lowercase → uppercase transition).
///
/// Unlike ``isWordBoundary(at:in:)`` which detects all boundary types, this function
/// specifically checks for ASCII lowercase-to-uppercase transitions. Used by the
/// Smith-Waterman algorithm to award ``SmithWatermanConfig/bonusCamelCase`` separately
/// from ``SmithWatermanConfig/bonusBoundary``.
///
/// - Parameters:
///   - index: The position to check (0-based).
///   - bytes: The original (non-lowercased) UTF-8 byte buffer.
/// - Returns: `true` if the position has a lowercase-to-uppercase ASCII transition.
///
/// ## Example
///
/// ```swift
/// let bytes = Array("getUserById".utf8)
/// bytes.withUnsafeBufferPointer { ptr in
///     isCamelCaseBoundary(at: 3, in: ptr)  // true ('t' → 'U')
///     isCamelCaseBoundary(at: 0, in: ptr)  // false (no predecessor)
///     isCamelCaseBoundary(at: 4, in: ptr)  // false ('U' → 's')
/// }
/// ```
@inlinable
internal func isCamelCaseBoundary(
    at index: Int,
    in bytes: UnsafeBufferPointer<UInt8>
) -> Bool {
    guard index > 0 && index < bytes.count else { return false }
    let previous = bytes[index - 1]
    let current = bytes[index]
    let prevIsLower = (previous >= 0x61 && previous <= 0x7A)
    let currIsUpper = (current >= 0x41 && current <= 0x5A)
    return prevIsLower && currIsUpper
}

/// Precomputes word boundary positions as a bitmask.
///
/// Returns a `UInt64` where bit `i` is set if position `i` is a word boundary.
/// This bitmask enables O(1) boundary lookup during scoring, avoiding repeated
/// calls to ``isWordBoundary(at:in:)``.
///
/// - Note: Limited to first 64 characters. For identifiers longer than 64 characters,
///   use ``isWordBoundary(at:in:)`` directly for positions >= 64.
///
/// - Parameters:
///   - bytes: The UTF-8 byte buffer to analyze.
/// - Returns: A bitmask where bit `i` is set if position `i` is a word boundary.
///
/// ## Complexity
///
/// O(min(length, 64)) - linear in the number of characters analyzed.
///
/// ## Example
///
/// ```swift
/// let bytes = Array("getUserById".utf8)
/// let mask = bytes.withUnsafeBufferPointer { computeBoundaryMask(bytes: $0) }
///
/// // Check if position 3 is a boundary (the 'U' in 'User')
/// let isBoundary = (mask & (1 << 3)) != 0  // true
/// ```
@inlinable
internal func computeBoundaryMask(
    bytes: UnsafeBufferPointer<UInt8>
) -> UInt64 {
    var mask: UInt64 = 0
    let limit = min(bytes.count, 64)
    for i in 0..<limit {
        if isWordBoundary(at: i, in: bytes) {
            mask |= (1 << i)
        }
    }
    return mask
}

/// Advances output position and predecessor byte after a confusable normalization check.
///
/// If the confusable resolved to an ASCII byte (`ascii != 0`), the output advances by 1
/// (the multi-byte sequence collapsed). Otherwise it advances by the original `byteCount`.
@inlinable
internal func advanceConfusable(
    ascii: UInt8,
    lastOriginalByte: UInt8,
    byteCount: Int,
    prevMeaningfulByte: inout UInt8,
    outIdx: inout Int
) {
    if ascii != 0 {
        prevMeaningfulByte = ascii
        outIdx += 1
    } else {
        prevMeaningfulByte = lastOriginalByte
        outIdx += byteCount
    }
}

/// Precomputes word boundary positions in compressed (post-lowercasing) index space.
///
/// When combining diacritical marks (U+0300–U+036F) are stripped during lowercasing,
/// the original byte positions shift. This function walks the original bytes (needed
/// for camelCase detection) but assigns boundary bits at the **compressed** output
/// positions that correspond to where `lowercaseUTF8` places each byte.
///
/// For ASCII-only strings, positions are 1:1 and this delegates to ``computeBoundaryMask(bytes:)``.
///
/// - Parameters:
///   - originalBytes: The original (non-lowercased) UTF-8 byte buffer.
///   - isASCII: Whether the string is pure ASCII (no multi-byte sequences).
/// - Returns: A bitmask where bit `i` is set if compressed position `i` is a word boundary.
///
/// ## Complexity
///
/// O(min(length, 64)) - linear in the number of characters analyzed.
@inlinable
internal func computeBoundaryMaskCompressed(
    originalBytes: UnsafeBufferPointer<UInt8>,
    isASCII: Bool
) -> UInt64 {
    // ASCII fast path: no combining marks possible, positions are 1:1
    if isASCII {
        return computeBoundaryMask(bytes: originalBytes)
    }

    // Multi-byte path: walk original bytes, skip combining marks,
    // assign boundary bits at compressed output positions.
    // We track prevMeaningfulByte across combining mark skips so that
    // camelCase detection works even when marks sit between characters
    // (e.g. a\u{0301}B should detect a→B camelCase transition).
    var mask: UInt64 = 0
    var inIdx = 0
    var outIdx = 0
    let count = originalBytes.count
    // Last non-combining-mark byte seen (0 means "start of string")
    var prevMeaningfulByte: UInt8 = 0

    while inIdx < count && outIdx < 64 {
        let byte = originalBytes[inIdx]

        // Skip combining diacritical marks (same logic as lowercaseUTF8)
        if inIdx + 1 < count && isCombiningMark(lead: byte, second: originalBytes[inIdx + 1]) {
            inIdx += 2  // skip mark, don't advance outIdx, don't update prevMeaningfulByte
        } else {
            // Check boundary using prevMeaningfulByte for adjacency
            let isBoundary: Bool
            if outIdx == 0 {
                isBoundary = true  // position 0 is always a boundary
            } else {
                isBoundary = isWordBoundaryFromPrev(prev: prevMeaningfulByte, current: byte)
            }
            if isBoundary {
                mask |= (1 << outIdx)
            }

            // Track the last byte of this character as the meaningful predecessor
            if isMultiByteLead(byte) && inIdx + 1 < count {
                prevMeaningfulByte = originalBytes[inIdx + 1]
                inIdx += 2
                // Latin-1 diacritics that normalize to ASCII collapse from 2 bytes to 1
                if byte == 0xC3 && latin1ToASCII(lowercaseLatinExtended(prevMeaningfulByte)) != 0 {
                    outIdx += 1
                } else {
                    outIdx += 2
                }
            } else if (byte == 0xC2 || byte == 0xCA) && inIdx + 1 < count {
                let ascii = confusable2ByteToASCII(lead: byte, second: originalBytes[inIdx + 1])
                advanceConfusable(
                    ascii: ascii, lastOriginalByte: originalBytes[inIdx + 1],
                    byteCount: 2, prevMeaningfulByte: &prevMeaningfulByte, outIdx: &outIdx
                )
                inIdx += 2
            } else if byte == 0xE2 && inIdx + 2 < count {
                let ascii = confusable3ByteToASCII(second: originalBytes[inIdx + 1], third: originalBytes[inIdx + 2])
                advanceConfusable(
                    ascii: ascii, lastOriginalByte: originalBytes[inIdx + 2],
                    byteCount: 3, prevMeaningfulByte: &prevMeaningfulByte, outIdx: &outIdx
                )
                inIdx += 3
            } else {
                prevMeaningfulByte = byte
                inIdx += 1
                outIdx += 1
            }
        }
    }
    return mask
}
