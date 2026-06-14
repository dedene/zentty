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

import Testing

@testable import FuzzyMatch

/// Tests for combining diacritical mark stripping (U+0300–U+036F).
///
/// Combining marks modify the preceding base character (e.g., e + ◌́ = é).
/// The matcher strips these marks so decomposed forms match their base characters.
@Suite("Combining Diacritical Mark Tests")
struct CombiningMarkTests {
    // MARK: - Edit Distance Mode

    @Test("Decomposed café matches precomposed café (partial)")
    func decomposedMatchesPrecomposed() {
        let matcher = FuzzyMatcher()
        // "café" with combining acute: e + U+0301 → stripped to "cafe" (4 bytes)
        let decomposed = "caf\u{0065}\u{0301}"
        // "café" with precomposed é: U+00E9 → stays "café" with Latin-1 é (5 bytes)
        // These are different byte sequences, so this is a partial match
        let precomposed = "caf\u{00E9}"

        let query = matcher.prepare(decomposed)
        var buffer = matcher.makeBuffer()
        let result = matcher.score(precomposed, against: query, buffer: &buffer)
        #expect(result != nil, "Decomposed query should partially match precomposed candidate")
        if let result {
            #expect(result.score >= 0.7, "Score should be reasonable: \(result.score)")
        }
    }

    @Test("Precomposed café matches decomposed café (partial)")
    func precomposedMatchesDecomposed() {
        let matcher = FuzzyMatcher()
        // Precomposed keeps Latin-1 é, decomposed strips to plain 'e' — different byte sequences
        let precomposed = "caf\u{00E9}"
        let decomposed = "caf\u{0065}\u{0301}"

        let query = matcher.prepare(precomposed)
        var buffer = matcher.makeBuffer()
        let result = matcher.score(decomposed, against: query, buffer: &buffer)
        #expect(result != nil, "Precomposed query should partially match decomposed candidate")
        if let result {
            #expect(result.score >= 0.7, "Score should be reasonable: \(result.score)")
        }
    }

    @Test("Self-match with combining marks returns score 1.0")
    func selfMatchWithCombiningMarks() {
        let matcher = FuzzyMatcher()
        let decomposed = "caf\u{0065}\u{0301}"

        let query = matcher.prepare(decomposed)
        var buffer = matcher.makeBuffer()
        let result = matcher.score(decomposed, against: query, buffer: &buffer)
        #expect(result != nil, "Self-match should succeed")
        if let result {
            #expect(result.score == 1.0, "Self-match score should be 1.0, got \(result.score)")
        }
    }

    @Test("resume matches résumé with combining marks")
    func resumeMatchesWithCombiningAccents() {
        let matcher = FuzzyMatcher()
        // "résumé" using combining accents: e + combining acute
        let candidate = "r\u{0065}\u{0301}sum\u{0065}\u{0301}"

        let query = matcher.prepare("resume")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "Plain query should match candidate with combining marks")
        if let result {
            #expect(result.score >= 0.8, "Score should be high: \(result.score)")
        }
    }

    @Test("Query with combining marks matches plain candidate")
    func queryWithMarksMatchesPlain() {
        let matcher = FuzzyMatcher()
        // Query "résumé" with combining marks
        let queryStr = "r\u{0065}\u{0301}sum\u{0065}\u{0301}"

        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let result = matcher.score("resume", against: query, buffer: &buffer)
        #expect(result != nil, "Query with combining marks should match plain candidate")
        if let result {
            #expect(result.score >= 0.8, "Score should be high: \(result.score)")
        }
    }

    @Test("Multiple combining marks are all stripped")
    func multipleCombiningMarksStripped() {
        let matcher = FuzzyMatcher()
        // "a" + combining grave (U+0300) + combining acute (U+0301) + combining circumflex (U+0302)
        let candidate = "a\u{0300}\u{0301}\u{0302}bc"

        let query = matcher.prepare("abc")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "Should match after stripping all combining marks")
        if let result {
            #expect(result.score == 1.0, "Should be exact match after stripping, got \(result.score)")
        }
    }

    // MARK: - Smith-Waterman Mode

    @Test("SW: Plain query matches candidate with combining marks")
    func swPlainMatchesCombiningCandidate() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        // Candidate has combining marks that get stripped to match plain query
        let candidate = "caf\u{0065}\u{0301}"  // → stripped to "cafe"

        let query = matcher.prepare("cafe")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "SW: Plain query should match candidate with stripped marks")
        if let result {
            #expect(result.score == 1.0, "Should be exact after stripping: \(result.score)")
        }
    }

    @Test("SW: Self-match with combining marks returns score 1.0")
    func swSelfMatchWithCombiningMarks() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let decomposed = "caf\u{0065}\u{0301}"

        let query = matcher.prepare(decomposed)
        var buffer = matcher.makeBuffer()
        let result = matcher.score(decomposed, against: query, buffer: &buffer)
        #expect(result != nil, "SW: Self-match should succeed")
        if let result {
            #expect(result.score == 1.0, "SW: Self-match score should be 1.0, got \(result.score)")
        }
    }

    @Test("SW: resume matches résumé with combining marks")
    func swResumeMatchesWithCombiningAccents() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let candidate = "r\u{0065}\u{0301}sum\u{0065}\u{0301}"

        let query = matcher.prepare("resume")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "SW: Plain query should match candidate with combining marks")
        if let result {
            #expect(result.score >= 0.8, "Score should be high: \(result.score)")
        }
    }

    @Test("SW: Query with combining marks matches plain candidate")
    func swQueryWithMarksMatchesPlain() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let queryStr = "r\u{0065}\u{0301}sum\u{0065}\u{0301}"

        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let result = matcher.score("resume", against: query, buffer: &buffer)
        #expect(result != nil, "SW: Query with combining marks should match plain candidate")
        if let result {
            #expect(result.score >= 0.8, "Score should be high: \(result.score)")
        }
    }

    // MARK: - Combining Mark Helper

    // MARK: - Boundary Mask Alignment

    @Test("Boundary mask aligns with compressed positions when combining marks shift indices")
    func boundaryMaskCompressedAlignment() {
        // "ha\u{0308}llo_world" — decomposed ä in the middle shifts byte positions
        // Original bytes: h a CC 88 l l o _ w o r l d  (13 bytes)
        // Compressed:      h a l l o _ w o r l d        (11 bytes)
        // Boundary at compressed position 0 (h) and 6 (_w → w is boundary)
        let candidate = "ha\u{0308}llo_world"
        let originalBytes = Array(candidate.utf8)
        let mask = computeBoundaryMaskCompressed(
            originalBytes: originalBytes,
            isASCII: false
        )
        // Position 0 should be a boundary (start of string)
        #expect((mask & (1 << 0)) != 0, "Position 0 should be boundary")
        // Position 6 in compressed space = 'w' after '_' should be boundary
        #expect((mask & (1 << 6)) != 0, "Position 6 (w after _) should be boundary in compressed space")
    }

    @Test("CamelCase boundary detected across combining mark")
    func camelCaseBoundaryAcrossCombiningMark() {
        // "a\u{0301}Bcd" — combining acute between 'a' and 'B'
        // Compressed: "aBcd" — should have camelCase boundary at position 1 (a→B)
        let bytes = Array("a\u{0301}Bcd".utf8)
        let mask = computeBoundaryMaskCompressed(
            originalBytes: bytes,
            isASCII: false
        )
        // Position 0: boundary (start of string)
        #expect((mask & (1 << 0)) != 0, "Position 0 should be boundary")
        // Position 1 in compressed space: 'B' after 'a' — camelCase boundary
        #expect((mask & (1 << 1)) != 0, "Position 1 (B after a) should be camelCase boundary even with combining mark between them")
    }

    @Test("Combining mark candidate scores same as precomposed for boundary bonuses")
    func combiningMarkBoundaryBonusConsistency() {
        let matcher = FuzzyMatcher()
        // Decomposed form: "hä" + "llo_world" with combining mark
        let decomposed = "ha\u{0308}llo_world"
        // Precomposed form: "hällo_world" with precomposed ä (U+00E4)
        let precomposed = "h\u{00E4}llo_world"

        let query = matcher.prepare("hw")
        var buffer = matcher.makeBuffer()

        let decompResult = matcher.score(decomposed, against: query, buffer: &buffer)
        let precompResult = matcher.score(precomposed, against: query, buffer: &buffer)

        // Both should match and produce the same score and kind
        #expect(decompResult != nil, "Decomposed candidate should match")
        #expect(precompResult != nil, "Precomposed candidate should match")
        // Scores may differ slightly because decomposed strips the combining mark
        // (reducing compressed length by 1 byte vs precomposed 2-byte ä), which
        // affects length penalties. Check they're close and same kind.
        if let d = decompResult, let p = precompResult {
            #expect(abs(d.score - p.score) < 0.06, "Decomposed (\(d.score)) and precomposed (\(p.score)) scores should be close")
            #expect(d.kind == p.kind, "Decomposed (\(d.kind)) and precomposed (\(p.kind)) kinds should match")
        }
    }

    @Test("SW: Combining mark candidate scores same as precomposed for boundary bonuses")
    func swCombiningMarkBoundaryBonusConsistency() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let decomposed = "ha\u{0308}llo_world"
        let precomposed = "h\u{00E4}llo_world"

        let query = matcher.prepare("hw")
        var buffer = matcher.makeBuffer()

        let decompResult = matcher.score(decomposed, against: query, buffer: &buffer)
        let precompResult = matcher.score(precomposed, against: query, buffer: &buffer)

        #expect(decompResult != nil, "SW: Decomposed candidate should match")
        #expect(precompResult != nil, "SW: Precomposed candidate should match")
        if let d = decompResult, let p = precompResult {
            #expect(abs(d.score - p.score) < 0.05, "SW: Decomposed (\(d.score)) and precomposed (\(p.score)) scores should be close")
            #expect(d.kind == p.kind, "SW: Decomposed (\(d.kind)) and precomposed (\(p.kind)) kinds should match")
        }
    }

    // MARK: - Long Candidate Acronym (>64 bytes)

    @Test("Acronym gate counts words beyond byte 64")
    func acronymGateBeyond64Bytes() {
        let matcher = FuzzyMatcher()
        // Long first word pushes most boundaries past byte 64.
        // The first 66 bytes are one word of 'a's. Then _bb, _cc, _dd add 3 more words.
        // Without fix: wordCount from mask = 1 (only position 0), gate fails for query "abcd" (needs 4).
        // With fix: wordCount = 4 (position 0 + 3 boundaries beyond 64), gate passes.
        let longWord = String(repeating: "a", count: 66)
        let candidate = longWord + "_bb_cc_dd"

        let query = matcher.prepare("abcd")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "Acronym should match when word count gate includes words beyond byte 64")
        if let result {
            #expect(result.kind == .acronym, "Match should be acronym kind, got \(result.kind)")
        }
    }

    @Test("SW: Acronym gate counts words beyond byte 64")
    func swAcronymGateBeyond64Bytes() {
        let matcher = FuzzyMatcher(config: .smithWaterman)
        let longWord = String(repeating: "a", count: 66)
        let candidate = longWord + "_bb_cc_dd"

        let query = matcher.prepare("abcd")
        var buffer = matcher.makeBuffer()
        let result = matcher.score(candidate, against: query, buffer: &buffer)
        #expect(result != nil, "SW: Acronym should match when word count gate includes words beyond byte 64")
    }

    // MARK: - Combining Mark Helper

    @Test("isCombiningMark detects valid ranges")
    func combiningMarkDetection() {
        // U+0300 = 0xCC 0x80
        #expect(isCombiningMark(lead: 0xCC, second: 0x80) == true)
        // U+033F = 0xCC 0xBF
        #expect(isCombiningMark(lead: 0xCC, second: 0xBF) == true)
        // U+0340 = 0xCD 0x80
        #expect(isCombiningMark(lead: 0xCD, second: 0x80) == true)
        // U+036F = 0xCD 0xAF
        #expect(isCombiningMark(lead: 0xCD, second: 0xAF) == true)
        // Not a combining mark: U+0370 = 0xCD 0xB0
        #expect(isCombiningMark(lead: 0xCD, second: 0xB0) == false)
        // Not a combining mark: regular Latin-1 lead
        #expect(isCombiningMark(lead: 0xC3, second: 0xA9) == false)
        // Not a combining mark: ASCII
        #expect(isCombiningMark(lead: 0x41, second: 0x42) == false)
    }
}
