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

@Suite("Tiny Query Fast Path Tests")
struct TinyQueryFastPathTests {
    let matcher = FuzzyMatcher()

    // MARK: - Score Equivalence (fast path vs full pipeline)

    /// Helper that scores via the full pipeline (bypassing the fast path)
    /// by calling scoreImpl directly.
    private func scoreViaFullPipeline(
        _ candidate: String,
        against query: FuzzyQuery
    ) -> ScoredMatch? {
        var buffer = matcher.makeBuffer()
        buffer.recordUsage(queryLength: query.lowercased.count, candidateLength: candidate.utf8.count)
        let candidateUTF8 = Array(candidate.utf8)
        return candidateUTF8.withUnsafeBufferPointer { ptr in
            matcher.scoreImpl(
                ptr,
                against: query,
                edConfig: query.config.editDistanceConfig ?? .default,
                candidateStorage: &buffer.candidateStorage,
                editDistanceState: &buffer.editDistanceState,
                matchPositions: &buffer.matchPositions,
                alignmentState: &buffer.alignmentState,
                wordInitials: &buffer.wordInitials
            )
        }
    }

    @Test("1-char query score matches full pipeline")
    func oneCharScoreEquivalence() {
        let pairs: [(String, String)] = [
            ("a", "a"),
            ("a", "Apple"),
            ("a", "banana"),
            ("g", "getUserById"),
            ("x", "index"),
            ("u", "user"),
            ("u", "User"),
            ("5", "test5value")
        ]
        for (q, c) in pairs {
            let query = matcher.prepare(q)
            var buffer = matcher.makeBuffer()
            let fast = matcher.score(c, against: query, buffer: &buffer)
            let full = scoreViaFullPipeline(c, against: query)
            if let f = fast, let p = full {
                #expect(abs(f.score - p.score) < 0.001,
                    "Score mismatch for q=\(q) c=\(c): fast=\(f.score) full=\(p.score)")
            } else {
                #expect((fast == nil) == (full == nil),
                    "Nil mismatch for q=\(q) c=\(c): fast=\(fast?.score as Any) full=\(full?.score as Any)")
            }
        }
    }

    // MARK: - Match Kinds

    @Test("1-char exact match")
    func oneCharExact() {
        let query = matcher.prepare("a")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("a", against: query, buffer: &buffer)
        #expect(result?.kind == .exact)
        #expect(result?.score == 1.0)
    }

    @Test("1-char exact case-insensitive")
    func oneCharExactCaseInsensitive() {
        let query = matcher.prepare("a")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("A", against: query, buffer: &buffer)
        #expect(result?.kind == .exact)
        #expect(result?.score == 1.0)
    }

    @Test("1-char prefix match")
    func oneCharPrefix() {
        let query = matcher.prepare("g")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("getUserById", against: query, buffer: &buffer)
        #expect(result?.kind == .prefix)
        #expect(result != nil)
    }

    @Test("1-char substring match")
    func oneCharSubstring() {
        let query = matcher.prepare("x")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("index", against: query, buffer: &buffer)
        #expect(result?.kind == .substring)
    }

    // MARK: - Edge Cases

    @Test("1-char query against empty candidate")
    func oneCharEmptyCandidate() {
        let query = matcher.prepare("a")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("", against: query, buffer: &buffer)
        #expect(result == nil)
    }

    @Test("Digit query")
    func digitQuery() {
        let query = matcher.prepare("5")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("test5value", against: query, buffer: &buffer)
        #expect(result != nil)
    }

    @Test("Underscore boundary")
    func underscoreBoundary() {
        let query = matcher.prepare("u")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("get_user", against: query, buffer: &buffer)
        #expect(result != nil)
    }

    @Test("CamelCase boundary preferred")
    func camelCaseBoundary() {
        let query = matcher.prepare("u")
        var buffer = matcher.makeBuffer()
        // 'U' at position 3 in getUserById is a word boundary
        let result = matcher.score("getUserById", against: query, buffer: &buffer)
        #expect(result != nil)
    }

    // MARK: - No-match Cases

    @Test("1-char no match")
    func oneCharNoMatch() {
        let query = matcher.prepare("z")
        var buffer = matcher.makeBuffer()
        let result = matcher.score("apple", against: query, buffer: &buffer)
        #expect(result == nil)
    }

    // MARK: - Ranking Preservation

    @Test("1-char prefix ranks above substring")
    func oneCharPrefixRanksAboveSubstring() {
        let query = matcher.prepare("g")
        var buffer = matcher.makeBuffer()
        let prefix = matcher.score("get", against: query, buffer: &buffer)
        let substring = matcher.score("big", against: query, buffer: &buffer)
        #expect(prefix != nil)
        #expect(substring != nil)
        #expect(prefix!.score > substring!.score)
    }

    @Test("1-char exact ranks above prefix")
    func oneCharExactRanksAbovePrefix() {
        let query = matcher.prepare("a")
        var buffer = matcher.makeBuffer()
        let exact = matcher.score("a", against: query, buffer: &buffer)
        let prefix = matcher.score("apple", against: query, buffer: &buffer)
        #expect(exact != nil)
        #expect(prefix != nil)
        #expect(exact!.score > prefix!.score)
    }

    @Test("1-char shorter candidate scores higher")
    func oneCharShorterCandidateWins() {
        let query = matcher.prepare("g")
        var buffer = matcher.makeBuffer()
        let short = matcher.score("get", against: query, buffer: &buffer)
        let long = matcher.score("getUserById", against: query, buffer: &buffer)
        #expect(short != nil)
        #expect(long != nil)
        #expect(short!.score > long!.score)
    }
}
