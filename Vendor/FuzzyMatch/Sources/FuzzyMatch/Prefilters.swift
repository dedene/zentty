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

/// Prefilter functions for fast rejection of non-matching candidates.
///
/// Prefilters are lightweight checks that quickly reject candidates that cannot
/// possibly match within the allowed edit distance. They run before the expensive
/// edit distance computation.
///
/// ## Prefilter Pipeline
///
/// ```
/// Candidate → Length Bounds → Character Bitmask → (Trigrams) → Edit Distance
///               O(1)             O(1)               O(n)          O(nm)
/// ```
///
/// Each prefilter has increasing cost but catches candidates the previous filter missed.

/// Converts an ASCII uppercase letter to lowercase.
///
/// Uses bitwise OR to set the lowercase bit (0x20) for ASCII letters A-Z.
/// Non-ASCII bytes and non-letter bytes pass through unchanged.
///
/// - Parameter byte: The byte to convert.
/// - Returns: The lowercased byte if it was an uppercase ASCII letter,
///   otherwise the original byte.
///
/// ## Implementation
///
/// ASCII uppercase letters are in range 0x41-0x5A (A-Z).
/// ASCII lowercase letters are in range 0x61-0x7A (a-z).
/// The difference is bit 5 (0x20), so `byte | 0x20` converts to lowercase.
@inlinable
internal func lowercaseASCII(_ byte: UInt8) -> UInt8 {
    (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
}

/// Checks if a byte is a Latin-1 Supplement lead byte (0xC3).
///
/// In UTF-8, Latin-1 Supplement characters (U+00C0-U+00FF) are encoded as
/// two-byte sequences starting with 0xC3. The second byte determines the
/// specific character.
@inlinable
internal func isLatinExtendedLead(_ byte: UInt8) -> Bool {
    byte == 0xC3
}

/// Checks if a byte is a 2-byte UTF-8 lead byte for Latin-1, Greek, or Cyrillic.
///
/// Returns `true` for:
/// - 0xC3: Latin-1 Supplement (U+00C0-U+00FF)
/// - 0xCE, 0xCF: Greek (U+0370-U+03FF)
/// - 0xD0, 0xD1: Cyrillic basic (U+0400-U+047F)
@inlinable
internal func isMultiByteLead(_ byte: UInt8) -> Bool {
    byte == 0xC3 ||
    byte == 0xCE || byte == 0xCF ||
    byte == 0xD0 || byte == 0xD1
}

/// Checks if a 2-byte UTF-8 sequence is a combining diacritical mark (U+0300–U+036F).
///
/// Combining marks are encoded as:
/// - 0xCC 0x80–0xBF → U+0300–U+033F
/// - 0xCD 0x80–0xAF → U+0340–U+036F
///
/// These marks modify the preceding base character (e.g., e + ◌́ = é) and are
/// stripped during matching so that decomposed forms match their base characters.
@inlinable
internal func isCombiningMark(lead: UInt8, second: UInt8) -> Bool {
    (lead == 0xCC && second >= 0x80 && second <= 0xBF) ||
    (lead == 0xCD && second >= 0x80 && second <= 0xAF)
}

/// Maps a lowercased Latin-1 Supplement second byte to its ASCII base letter.
///
/// Returns the ASCII letter (e.g., `0x61` for 'a') if the character is a diacritic
/// variant of an ASCII letter, or `0` if no mapping exists. Characters returning `0`
/// include ligatures (æ), distinct letters (ð, þ, ø, ß), and non-letters (×, ÷).
///
/// This function expects the second byte to already be lowercased (in range 0xA0–0xBF
/// for letters). Call ``lowercaseLatinExtended(_:)`` first if the byte may be uppercase.
///
/// - Parameter lowercasedSecondByte: The lowercased second byte of a 0xC3-prefixed UTF-8 sequence.
/// - Returns: The ASCII base letter (0x61–0x7A), or `0` if no mapping exists.
@inlinable
internal func latin1ToASCII(_ lowercasedSecondByte: UInt8) -> UInt8 {
    switch lowercasedSecondByte {
    case 0xA0...0xA5: return 0x61  // à-å → a
    case 0xA7: return 0x63          // ç → c
    case 0xA8...0xAB: return 0x65  // è-ë → e
    case 0xAC...0xAF: return 0x69  // ì-ï → i
    case 0xB1: return 0x6E          // ñ → n
    case 0xB2...0xB6: return 0x6F  // ò-ö → o
    case 0xB9...0xBC: return 0x75  // ù-ü → u
    case 0xBD: return 0x79          // ý → y
    case 0xBF: return 0x79          // ÿ → y
    default: return 0               // æ, ð, ø, þ, ß, ×, ÷ — no ASCII base
    }
}

/// Maps a 2-byte UTF-8 confusable to its canonical ASCII byte.
///
/// Handles confusable characters with lead bytes 0xC2 and 0xCA:
/// - 0xC2 0xA0 (NBSP U+00A0) → 0x20 (space)
/// - 0xC2 0xB4 (acute accent U+00B4) → 0x27 (apostrophe)
/// - 0xCA 0xBB (ʻokina U+02BB) → 0x27 (apostrophe)
/// - 0xCA 0xBC (modifier apostrophe U+02BC) → 0x27 (apostrophe)
///
/// - Parameters:
///   - lead: The lead byte (0xC2 or 0xCA).
///   - second: The second byte of the UTF-8 sequence.
/// - Returns: The canonical ASCII byte, or `0` if no mapping exists.
@inlinable
internal func confusable2ByteToASCII(lead: UInt8, second: UInt8) -> UInt8 {
    switch (lead, second) {
    case (0xC2, 0xA0): return 0x20 // NBSP → space
    case (0xC2, 0xB4): return 0x27 // acute accent → apostrophe
    case (0xCA, 0xBB), (0xCA, 0xBC): return 0x27 // ʻokina, modifier apostrophe → '
    default: return 0
    }
}

/// Maps a 3-byte UTF-8 confusable (0xE2 lead) to its canonical ASCII byte.
///
/// Handles confusable characters with lead byte 0xE2:
/// - 0xE2 0x80 0x98–0x99 (curly single quotes U+2018–2019) → 0x27 (apostrophe)
/// - 0xE2 0x80 0x9C–0x9D (curly double quotes U+201C–201D) → 0x22 (double quote)
/// - 0xE2 0x80 0x90–0x94 (hyphens/dashes U+2010–2014) → 0x2D (hyphen-minus)
/// - 0xE2 0x88 0x92 (minus sign U+2212) → 0x2D (hyphen-minus)
///
/// - Parameters:
///   - second: The second byte of the 0xE2-prefixed UTF-8 sequence.
///   - third: The third byte of the UTF-8 sequence.
/// - Returns: The canonical ASCII byte, or `0` if no mapping exists.
@inlinable
internal func confusable3ByteToASCII(second: UInt8, third: UInt8) -> UInt8 {
    switch (second, third) {
    case (0x80, 0x98), (0x80, 0x99): return 0x27 // curly single quotes → '
    case (0x80, 0x9C), (0x80, 0x9D): return 0x22 // curly double quotes → "
    case (0x80, 0x90...0x94): return 0x2D // hyphens/dashes → -
    case (0x88, 0x92): return 0x2D // minus sign → -
    default: return 0
    }
}

/// Maps an ASCII confusable to its canonical form.
///
/// Currently handles:
/// - 0x60 (grave accent `` ` ``) → 0x27 (apostrophe `'`)
///
/// - Parameter byte: The ASCII byte to check.
/// - Returns: The canonical ASCII byte, or the original byte if no mapping exists.
@inlinable
internal func confusableASCIIToCanonical(_ byte: UInt8) -> UInt8 {
    byte == 0x60 ? 0x27 : byte
}

/// Lowercases the second byte of a 2-byte UTF-8 Latin-1 Supplement sequence.
///
/// Uppercase Latin-1 Supplement characters (U+00C0-U+00DE, except U+00D7 ×)
/// are encoded as 0xC3 followed by 0x80-0x9E. Adding 0x20 to the second byte
/// converts to the corresponding lowercase character (U+00E0-U+00FE, except U+00F7 ÷).
///
/// - Parameter secondByte: The second byte of a 0xC3-prefixed UTF-8 sequence.
/// - Returns: The lowercased second byte if it was uppercase Latin-1, otherwise unchanged.
@inlinable
internal func lowercaseLatinExtended(_ secondByte: UInt8) -> UInt8 {
    // 0x80-0x9E maps to uppercase U+00C0-U+00DE
    // 0x97 = U+00D7 (multiplication sign ×) is NOT a letter, skip it
    if secondByte >= 0x80 && secondByte <= 0x9E && secondByte != 0x97 {
        return secondByte + 0x20
    }
    return secondByte
}

/// Lowercases the second byte of a 2-byte UTF-8 Greek sequence.
///
/// Greek uppercase characters are encoded in two ranges:
/// - CE 91–9F (Α-Ο): lowercase = CE B1–BF (add 0x20 to second byte)
/// - CE A0–A9 (Π-Ω): lowercase = CF 80–89 (change lead to CF, subtract 0x20)
///
/// - Parameters:
///   - lead: The lead byte (0xCE or 0xCF).
///   - second: The second byte of the UTF-8 sequence.
/// - Returns: The lowercased (lead, second) pair.
@inlinable
internal func lowercaseGreek(lead: UInt8, second: UInt8) -> (UInt8, UInt8) {
    if lead == 0xCE {
        // CE 91-9F → CE B1-BF (uppercase Α-Ο → lowercase α-ο)
        if second >= 0x91 && second <= 0x9F {
            return (0xCE, second &+ 0x20)
        }
        // CE A0-A9 → CF 80-89 (uppercase Π-Ω → lowercase π-ω, skip A2)
        if second >= 0xA0 && second <= 0xA9 && second != 0xA2 {
            return (0xCF, second &- 0x20)
        }
    }
    return (lead, second)
}

/// Lowercases the second byte of a 2-byte UTF-8 Cyrillic sequence.
///
/// Cyrillic uppercase characters are encoded in three ranges:
/// - D0 90–9F (А-П): lowercase = D0 B0–BF (add 0x20 to second byte)
/// - D0 A0–AF (Р-Я): lowercase = D1 80–8F (change lead to D1, subtract 0x20)
/// - D0 80–8F (Ё etc., U+0400-U+040F): lowercase = D1 90–9F (change lead to D1, add 0x10)
///
/// - Parameters:
///   - lead: The lead byte (0xD0 or 0xD1).
///   - second: The second byte of the UTF-8 sequence.
/// - Returns: The lowercased (lead, second) pair.
@inlinable
internal func lowercaseCyrillic(lead: UInt8, second: UInt8) -> (UInt8, UInt8) {
    if lead == 0xD0 {
        // D0 90-9F → D0 B0-BF (uppercase А-П → lowercase а-п)
        if second >= 0x90 && second <= 0x9F {
            return (0xD0, second &+ 0x20)
        }
        // D0 A0-AF → D1 80-8F (uppercase Р-Я → lowercase р-я)
        if second >= 0xA0 && second <= 0xAF {
            return (0xD1, second &- 0x20)
        }
        // D0 80-8F → D1 90-9F (uppercase Ё etc. → lowercase ё etc.)
        if second >= 0x80 && second <= 0x8F {
            return (0xD1, second &+ 0x10)
        }
    }
    return (lead, second)
}

/// Lowercases a UTF-8 byte sequence, handling ASCII, Latin-1 Supplement, Greek, and Cyrillic.
///
/// The destination array must have at least `source.count` elements allocated.
/// Combining diacritical marks (U+0300–U+036F) are stripped during lowercasing,
/// so the output may be shorter than the input. The actual output length is returned.
///
/// - Parameters:
///   - source: Raw UTF-8 bytes to lowercase.
///   - destination: Pre-allocated array to write lowercased bytes into.
///   - mapping: If non-nil, records `mapping[outIdx] = sourceIdx` for each output byte,
///     enabling callers to map normalized positions back to original byte offsets.
///     The buffer must have at least `source.count` elements. Pass `nil` on the hot path;
///     the compiler dead-code-eliminates all mapping writes when specialized with `nil`.
///   - isASCII: If `true`, uses the faster ASCII-only path (no multi-byte dispatch).
/// - Returns: The number of bytes written to `destination`.
@inlinable @discardableResult
internal func lowercaseUTF8(
    from source: UnsafeBufferPointer<UInt8>,
    into destination: inout [UInt8],
    mapping: UnsafeMutablePointer<Int>?,
    isASCII: Bool
) -> Int {
    let count = source.count
    if count == 0 { return 0 }
    // Use withUnsafeMutableBufferPointer to bypass Array.subscript.modify coroutine
    // overhead. Each array subscript write normally goes through a yield-once coroutine
    // with bounds checking; direct pointer writes eliminate this for the O(n) pass.
    return destination.withUnsafeMutableBufferPointer { destPtr in
        let dest = destPtr.baseAddress!
        if isASCII {
            for i in 0..<count {
                dest[i] = confusableASCIIToCanonical(lowercaseASCII(source[i]))
                mapping?[i] = i
            }
            return count
        } else {
            var i = 0
            var outIdx = 0
            while i < count {
                let byte = source[i]
                // Skip combining diacritical marks (U+0300–U+036F)
                if i + 1 < count && isCombiningMark(lead: byte, second: source[i + 1]) {
                    i += 2
                } else if byte == 0xC3 && i + 1 < count {
                    let lowered = lowercaseLatinExtended(source[i + 1])
                    let ascii = latin1ToASCII(lowered)
                    if ascii != 0 {
                        dest[outIdx] = ascii
                        mapping?[outIdx] = i
                        outIdx += 1
                    } else {
                        dest[outIdx] = byte
                        mapping?[outIdx] = i
                        dest[outIdx + 1] = lowered
                        mapping?[outIdx + 1] = i
                        outIdx += 2
                    }
                    i += 2
                } else if (byte == 0xCE || byte == 0xCF) && i + 1 < count {
                    let (newLead, newSecond) = lowercaseGreek(lead: byte, second: source[i + 1])
                    dest[outIdx] = newLead
                    mapping?[outIdx] = i
                    dest[outIdx + 1] = newSecond
                    mapping?[outIdx + 1] = i
                    outIdx += 2
                    i += 2
                } else if (byte == 0xD0 || byte == 0xD1) && i + 1 < count {
                    let (newLead, newSecond) = lowercaseCyrillic(lead: byte, second: source[i + 1])
                    dest[outIdx] = newLead
                    mapping?[outIdx] = i
                    dest[outIdx + 1] = newSecond
                    mapping?[outIdx + 1] = i
                    outIdx += 2
                    i += 2
                } else if (byte == 0xC2 || byte == 0xCA) && i + 1 < count {
                    let ascii = confusable2ByteToASCII(lead: byte, second: source[i + 1])
                    if ascii != 0 {
                        dest[outIdx] = ascii
                        mapping?[outIdx] = i
                        outIdx += 1
                    } else {
                        dest[outIdx] = byte
                        mapping?[outIdx] = i
                        dest[outIdx + 1] = source[i + 1]
                        mapping?[outIdx + 1] = i
                        outIdx += 2
                    }
                    i += 2
                } else if byte == 0xE2 && i + 2 < count {
                    let ascii = confusable3ByteToASCII(second: source[i + 1], third: source[i + 2])
                    if ascii != 0 {
                        dest[outIdx] = ascii
                        mapping?[outIdx] = i
                        outIdx += 1
                    } else {
                        dest[outIdx] = byte
                        mapping?[outIdx] = i
                        dest[outIdx + 1] = source[i + 1]
                        mapping?[outIdx + 1] = i
                        dest[outIdx + 2] = source[i + 2]
                        mapping?[outIdx + 2] = i
                        outIdx += 3
                    }
                    i += 3
                } else {
                    dest[outIdx] = confusableASCIIToCanonical(lowercaseASCII(byte))
                    mapping?[outIdx] = i
                    outIdx += 1
                    i += 1
                }
            }
            return outIdx
        }
    }
}

/// Maps a 2-byte UTF-8 character pair into a bit position in the extended bitmask.
///
/// Hashes the lowercased (lead, second) pair into bits 37–63 (27 available bits)
/// to extend the character bitmask for Greek, Cyrillic, and Latin-1 Supplement.
///
/// - Parameters:
///   - lead: The lead byte.
///   - second: The second byte.
/// - Returns: Bit position in range 37–63.
@inlinable
internal func charBitmaskBit2Byte(lead: UInt8, second: UInt8) -> Int {
    37 + Int((second ^ lead) % 27)
}

/// Computes a character presence bitmask for a sequence of lowercased UTF-8 bytes.
///
/// The bitmask is a 37-bit bloom filter that tracks which characters are present:
/// - Bits 0-25: Letters a-z
/// - Bits 26-35: Digits 0-9
/// - Bit 36: Underscore
///
/// - Parameter bytes: The lowercased UTF-8 bytes.
/// - Returns: A 64-bit integer with bits set for each present character type.
///
/// ## Usage
///
/// Compare query and candidate bitmasks to check that missing character types
/// are within the edit budget:
///
/// ```swift
/// let missingChars = queryMask & ~candidateMask
/// let withinBudget = missingChars.nonzeroBitCount <= maxEditDistance
/// ```
///
/// Each substitution edit can account for one missing character type.
@inlinable
internal func computeCharBitmask<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
    var mask: UInt64 = 0
    var iterator = bytes.makeIterator()
    while let byte = iterator.next() {
        if isMultiByteLead(byte) {
            if let second = iterator.next() {
                let bit = charBitmaskBit2Byte(lead: byte, second: second)
                mask |= (1 << bit)
            }
        } else {
            mask |= charBitmaskLookup[Int(byte)] & charBitmaskMask
        }
    }
    return mask
}

/// Computes a character presence bitmask for an UnsafeBufferPointer of lowercased UTF-8 bytes.
///
/// This overload works with UnsafeBufferPointer for direct buffer access.
@inlinable
internal func computeCharBitmask(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var mask: UInt64 = 0
    var i = 0
    while i < bytes.count {
        let byte = bytes[i]
        if isMultiByteLead(byte) && i + 1 < bytes.count {
            let bit = charBitmaskBit2Byte(lead: byte, second: bytes[i + 1])
            mask |= (1 << bit)
            i += 2
        } else {
            mask |= charBitmaskLookup[Int(byte)] & charBitmaskMask
            i += 1
        }
    }
    return mask
}

/// Computes a case-insensitive character presence bitmask for raw (non-lowercased) UTF-8 bytes.
///
/// Maps both uppercase (A-Z) and lowercase (a-z) to the same bits 0-25,
/// allowing bitmask comparison before paying the lowercasing cost.
///
/// - Bits 0-25: Letters a-z / A-Z (case-insensitive)
/// - Bits 26-35: Digits 0-9
/// - Bit 36: Underscore
///
/// - Parameter bytes: Raw UTF-8 bytes (not necessarily lowercased).
/// - Returns: A 64-bit integer with bits set for each present character type.
@inlinable
internal func computeCharBitmaskCaseInsensitive(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
    var mask: UInt64 = 0
    var i = 0
    while i < bytes.count {
        let byte = bytes[i]
        if isMultiByteLead(byte) && i + 1 < bytes.count {
            let second = bytes[i + 1]
            // Lowercase the pair, then hash
            if byte == 0xC3 {
                let lowered = lowercaseLatinExtended(second)
                let ascii = latin1ToASCII(lowered)
                if ascii != 0 {
                    // Diacritic normalizes to ASCII — use ASCII bit (0-25)
                    mask |= charBitmaskLookup[Int(ascii)] & charBitmaskMask
                } else {
                    let bit = charBitmaskBit2Byte(lead: byte, second: lowered)
                    mask |= (1 << bit)
                }
            } else if byte == 0xCE || byte == 0xCF {
                let lowered = lowercaseGreek(lead: byte, second: second)
                let bit = charBitmaskBit2Byte(lead: lowered.0, second: lowered.1)
                mask |= (1 << bit)
            } else {
                let lowered = lowercaseCyrillic(lead: byte, second: second)
                let bit = charBitmaskBit2Byte(lead: lowered.0, second: lowered.1)
                mask |= (1 << bit)
            }
            i += 2
        } else if (byte == 0xC2 || byte == 0xCA) && i + 1 < bytes.count {
            let ascii = confusable2ByteToASCII(lead: byte, second: bytes[i + 1])
            if ascii != 0 {
                mask |= charBitmaskLookup[Int(ascii)] & charBitmaskMask
            }
            // Non-confusable 2-byte chars: targets (', ", -, space) all map to 0 in bitmask
            i += 2
        } else if byte == 0xE2 && i + 2 < bytes.count {
            let ascii = confusable3ByteToASCII(second: bytes[i + 1], third: bytes[i + 2])
            if ascii != 0 {
                mask |= charBitmaskLookup[Int(ascii)] & charBitmaskMask
            }
            i += 3
        } else {
            mask |= charBitmaskLookup[Int(confusableASCIIToCanonical(byte))] & charBitmaskMask
            i += 1
        }
    }
    return mask
}

/// Lookup table mapping each byte (0-255) to its bitmask contribution.
///
/// - a-z (0x61-0x7A): bits 0-25
/// - A-Z (0x41-0x5A): bits 0-25 (same as lowercase)
/// - 0-9 (0x30-0x39): bits 26-35
/// - _ (0x5F): bit 36
/// - Bytes >= 0x80: bit 63 set as non-ASCII sentinel
/// - All other bytes: 0
@usableFromInline
internal let charBitmaskLookup: ContiguousArray<UInt64> = {
    var table = ContiguousArray<UInt64>(repeating: 0, count: 256)
    for b in UInt8(0x61)...UInt8(0x7A) { table[Int(b)] = UInt64(1) << (b &- 0x61) }  // a-z
    for b in UInt8(0x41)...UInt8(0x5A) { table[Int(b)] = UInt64(1) << (b &- 0x41) }  // A-Z
    for b in UInt8(0x30)...UInt8(0x39) { table[Int(b)] = UInt64(1) << (b &- 0x30 &+ 26) }  // 0-9
    table[0x5F] = UInt64(1) << 36  // underscore
    for b in 0x80...0xFF { table[b] = UInt64(1) << 63 }  // non-ASCII sentinel
    return table
}()

/// Bitmask for extracting the 37-bit character presence mask (clearing the sentinel bit).
@usableFromInline
internal let charBitmaskMask: UInt64 = (UInt64(1) << 37) &- 1

/// Computes a case-insensitive character bitmask and detects ASCII in a single O(n) pass.
///
/// Uses a 256-entry lookup table: one table load + one OR per byte with zero branches
/// in the ASCII fast path. If a non-ASCII byte is detected (via bit 63 sentinel),
/// falls back to the general multi-byte path.
///
/// - Parameter bytes: Raw UTF-8 bytes (not necessarily lowercased).
/// - Returns: A tuple of (bitmask, isASCII) where bitmask has bits set for present character types
///   and isASCII indicates whether all bytes are < 0x80.
///
/// ## Performance Note
///
/// The branch-free inner loop (single load + OR per byte) is critical for performance.
/// Adding a per-byte early-exit check (e.g. `if mask & queryMask == queryMask`) was
/// benchmarked and caused a ~10% regression: the added data-dependent branch prevents
/// compiler auto-vectorization and adds pipeline overhead that outweighs any savings
/// from scanning fewer bytes on typical-length candidates (20-50 bytes).
@inlinable
internal func computeCharBitmaskWithASCIICheck(_ bytes: UnsafeBufferPointer<UInt8>) -> (mask: UInt64, isASCII: Bool) {
    var mask: UInt64 = 0
    for i in 0..<bytes.count {
        mask |= charBitmaskLookup[Int(bytes[i])]
    }
    // Check sentinel bit: if set, at least one byte was >= 0x80
    if mask & (UInt64(1) << 63) != 0 {
        return (computeCharBitmaskCaseInsensitive(bytes), false)
    }
    return (mask, true)
}

/// Checks if a candidate passes the length bounds prefilter.
///
/// This check rejects candidates that are impossibly short. The minimum length
/// is `queryLength - maxEditDistance` to allow for deletions in edit-distance matching.
///
/// Unlike traditional edit-distance matchers, we don't impose a strict upper bound
/// because subsequence matching can match short queries against long
/// candidates (e.g., "fb" matching "file_browser").
///
/// - Parameters:
///   - candidateLength: Length of the candidate string in bytes.
///   - queryLength: Length of the query string in bytes.
///   - maxEditDistance: Maximum allowed edit distance.
/// - Returns: `true` if the candidate passes the length check.
///
/// ## Bounds
///
/// - **Minimum**: `queryLength - maxEditDistance` (allows for deletions)
/// - **Maximum**: No strict upper limit (allows subsequence matching)
///
/// ## Complexity
///
/// O(1) - simple arithmetic comparison.
@inlinable
internal func passesLengthBounds(
    candidateLength: Int,
    queryLength: Int,
    maxEditDistance: Int
) -> Bool {
    candidateLength >= queryLength - maxEditDistance
}

/// Checks if a candidate passes the character bitmask prefilter.
///
/// Characters present in the query should mostly be present in the candidate.
/// The number of distinct missing character types is allowed up to `maxEditDistance`,
/// since each substitution edit can account for one missing character.
///
/// - Parameters:
///   - queryMask: The query's character bitmask from ``computeCharBitmask(_:)``.
///   - candidateMask: The candidate's character bitmask.
///   - maxEditDistance: Maximum allowed edit distance. Each substitution can account
///     for one missing character type.
/// - Returns: `true` if the number of missing character types is within the edit budget.
///
/// ## Logic
///
/// ```
/// missingChars = queryMask & ~candidateMask
/// passes = popcount(missingChars) <= maxEditDistance
/// ```
///
/// ## Example
///
/// ```swift
/// // Query "usr" has bits for u, s, r set
/// // Candidate "user" has bits for u, s, e, r set
/// // missingChars = 0, popcount = 0 ≤ 2 → passes
///
/// // Query "hein" has bits for h, e, i, n set
/// // Candidate "heia" has bits for h, e, i, a set
/// // missingChars = bit for 'n', popcount = 1 ≤ 1 → passes (substitution)
///
/// // Query "gubi" has bits for g, u, b, i set
/// // Candidate "build" has bits for b, u, i, l, d set
/// // missingChars = bit for 'g', popcount = 1 ≤ 2 → passes
/// ```
///
/// ## Complexity
///
/// O(1) - bitwise operations and popcount.
@inlinable
internal func passesCharBitmask(
    queryMask: UInt64,
    candidateMask: UInt64,
    maxEditDistance: Int = 0
) -> Bool {
    let missingChars = queryMask & ~candidateMask
    return missingChars.nonzeroBitCount <= maxEditDistance
}
