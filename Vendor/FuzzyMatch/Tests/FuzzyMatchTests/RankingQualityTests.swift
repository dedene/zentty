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

// MARK: - Ranking Quality Tests
//
// These tests verify that the matcher produces correct relative ordering
// for common search patterns. Each test case specifies a query and
// candidates that should rank in a particular order.

/// Helper to rank candidates by score (highest first).
private func rank(
    _ query: String,
    against candidates: [String],
    config: MatchConfig = MatchConfig()
) -> [(candidate: String, score: Double)] {
    let matcher = FuzzyMatcher(config: config)
    let prepared = matcher.prepare(query)
    var buffer = matcher.makeBuffer()

    return candidates.compactMap { candidate in
        guard let match = matcher.score(candidate, against: prepared, buffer: &buffer) else {
            return nil
        }
        return (candidate, match.score)
    }.sorted { $0.score > $1.score }
}

/// Helper to verify that candidate A ranks higher than candidate B.
private func assertRanksHigher(
    query: String,
    higher: String,
    lower: String,
    config: MatchConfig = MatchConfig()
) {
    let results = rank(query, against: [higher, lower], config: config)
    guard results.count == 2 else {
        Issue.record("Expected 2 results for query '\(query)', got \(results.count)")
        return
    }
    #expect(
        results[0].candidate == higher,
        "Expected '\(higher)' (\(results.first { $0.candidate == higher }?.score ?? 0)) to rank higher than '\(lower)' (\(results.first { $0.candidate == lower }?.score ?? 0)) for query '\(query)'"
    )
}

// MARK: - Abbreviation Matching

@Test func abbreviationGubiMatchesGetUserById() {
    // "gubi" matches "getUserById" via subsequence (g,U,B,I at word boundaries).
    // "debugging" does NOT match — g,u,b,i cannot be found in order, and with
    // maxEdit=1 at 4 chars the edit distance paths also fail.
    let results = rank("gubi", against: ["getUserById", "debugging"])
    #expect(results.count == 1)
    #expect(results[0].candidate == "getUserById")
}

@Test func abbreviationFbPrefersFooBar() {
    assertRanksHigher(query: "fb", higher: "fooBar", lower: "fileBrowser")
}

// MARK: - Prefix Preference

@Test func prefixGetPrefersGetUser() {
    assertRanksHigher(query: "get", higher: "getUser", lower: "targetGet")
}

@Test func prefixSetPrefersSetName() {
    assertRanksHigher(query: "set", higher: "setName", lower: "resetAll")
}

// MARK: - Consecutive Runs

@Test func consecutiveConfigPrefersConfiguration() {
    assertRanksHigher(query: "config", higher: "configuration", lower: "configurable_item")
}

// MARK: - Typo Tolerance

@Test func typoUsrMatchesUser() {
    let results = rank("usr", against: ["user", "usher", "ultraShort"])
    #expect(results.count >= 1)
    // "user" should be in results
    #expect(results.contains { $0.candidate == "user" })
}

// MARK: - camelCase Matching

@Test func camelCaseSnPrefersSetName() {
    // "setna" at prefix of "setName" should rank higher than a non-boundary
    // substring match. Uses a 5-char query to avoid the short-query same-length
    // ED restriction (queries <= 4 chars only allow ED typos against same-length
    // candidates).
    assertRanksHigher(query: "setna", higher: "setName", lower: "asetnamed")
}

// MARK: - fzfAligned Config Tests

@Test func fzfAlignedPresetExists() {
    let config = MatchConfig.fzfAligned
    #expect(config.editDistanceConfig!.wordBoundaryBonus == 0.12)
    #expect(config.editDistanceConfig!.consecutiveBonus == 0.06)
    #expect(config.editDistanceConfig!.maxEditDistance == 2)
}

@Test func fzfAlignedAbbreviationRanking() {
    // "gubi" matches "getUserById" via subsequence (g,U,B,I at word boundaries).
    // "debugging" does NOT match — g,u,b,i can't be found in order, and
    // maxEdit=1 at 4 chars prevents edit distance matching.
    let results = rank("gubi", against: ["getUserById", "debugging"], config: .fzfAligned)
    #expect(results.count == 1)
    #expect(results[0].candidate == "getUserById")
}

@Test func fzfAlignedPrefixRanking() {
    assertRanksHigher(
        query: "get",
        higher: "getUser",
        lower: "targetGet",
        config: .fzfAligned
    )
}

@Test func fzfAlignedConsecutiveRanking() {
    assertRanksHigher(
        query: "config",
        higher: "configuration",
        lower: "configurable_item",
        config: .fzfAligned
    )
}

// MARK: - Trading Domain Ranking

@Test func tradingEquitySymbolSearch() {
    // Searching for "apple" should prefer the well-known equity name
    let results = rank("apple", against: [
        "Apple Inc",
        "Maple Finance",
        "Snapple Group"
    ])
    #expect(results.count >= 1)
    if let first = results.first {
        #expect(first.candidate == "Apple Inc")
    }
}

@Test func tradingDottedSymbolSearch() {
    // Dotted symbols like "MSFT.OQ" should be findable
    let results = rank("msft", against: [
        "MSFT.OQ",
        "MSFT.N",
        "MICROSOFT CORP"
    ])
    #expect(results.count >= 2)
}

@Test func tradingSlashedPairSearch() {
    // Slash-separated pairs like "EUR/USD" should be searchable
    let results = rank("eur", against: [
        "EUR/USD",
        "EUR/GBP",
        "NEURAL TECH"
    ])
    #expect(results.count >= 2)
}

@Test func tradingISharesGrouping() {
    // "ishares" should match iShares ETFs
    let results = rank("ishares", against: [
        "iShares Core S&P 500",
        "iShares MSCI World",
        "First Trust Shares"
    ])
    // iShares entries should rank higher (prefix match)
    if results.count >= 2 {
        #expect(results[0].candidate.hasPrefix("iShares"))
    }
}

// MARK: - Ranking Consistency

@Test func exactMatchScoresOne() {
    let results = rank("test", against: [
        "test",
        "contest",
        "attest"
    ])
    // Exact match should have score 1.0
    let exactMatch = results.first { $0.candidate == "test" }
    #expect(exactMatch != nil)
    #expect(exactMatch?.score == 1.0)
}

@Test func prefixMatchRanksAboveSubstring() {
    let results = rank("get", against: [
        "getUser",
        "budgetTracker"
    ])
    #expect(results.count == 2)
    #expect(results[0].candidate == "getUser")
}

// MARK: - Short Query Tie-Breaking (Prefer Prefix Over Subsequence)

@Test func shortQueryDNOPrefersExactOverSubsequence() {
    // "DNO" exact match should rank above "DAN O6 100..." subsequence match
    assertRanksHigher(
        query: "DNO",
        higher: "DNO",
        lower: "DAN O6 100 0.01 NORW"
    )
}

@Test func shortQueryTSLPrefersExactOverSubsequence() {
    // "TSL" exact match should rank above "TGS L6 140..." subsequence match
    assertRanksHigher(
        query: "TSL",
        higher: "TSL",
        lower: "TGS L6 140 0.01 NORW"
    )
}

@Test func shortQueryExactAlwaysBeatsSubsequenceInLongCandidate() {
    // Generic: a 3-char exact match must always outscore a subsequence
    // match in a 20+ char candidate
    assertRanksHigher(
        query: "ABC",
        higher: "ABC",
        lower: "A123 B456 C789 EXTRA"
    )
}

@Test func shorterCandidateWithSameMatchPreferred() {
    // When both are prefix matches, shorter candidate should score higher
    // (less "gap" after the match)
    let results = rank("get", against: [
        "getUser",
        "getUserByIdAndName"
    ])
    if results.count == 2 {
        #expect(results[0].candidate == "getUser")
    }
}

// MARK: - Market Picker Ranking (pickerMatchConfig)

@Test func marketPickerXSTOvsSTOX() {
    // Reproduces market picker scenario: searching "xsto" should rank XSTO
    // (exact match) far above STOX (prefix edit distance 1: delete 'x' → "sto" matches prefix "sto" of "stox").
    // Uses pickerMatchConfig: prefixWeight=4.0, substringWeight=0.5
    let config = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))
    let matcher = FuzzyMatcher(config: config)
    let query = matcher.prepare("xsto")
    var buffer = matcher.makeBuffer()

    let xsto = matcher.score("XSTO", against: query, buffer: &buffer)
    let stox = matcher.score("STOX", against: query, buffer: &buffer)
    let stoxxLimited = matcher.score("STOXX LIMITED", against: query, buffer: &buffer)
    let nasdaqStockholm = matcher.score("NASDAQ STOCKHOLM AB", against: query, buffer: &buffer)

    // XSTO is an exact match (case-insensitive) — should score 1.0
    #expect(xsto != nil)
    #expect(xsto!.score == 1.0)

    // STOX gets prefix edit distance 1 (delete leading 'x' from query → "sto" matches prefix).
    // With prefixWeight=4.0: score = 1.0 - 0.25/4.0 = 0.9375
    // This is expected — it's a fuzzy match, not an exact match.
    #expect(stox != nil)
    #expect(stox!.score > 0.9)
    #expect(stox!.score < 1.0)

    // STOXX LIMITED also gets a fuzzy prefix match (same mechanism)
    #expect(stoxxLimited != nil)

    // Critical: XSTO must rank strictly above STOX
    #expect(xsto!.score > stox!.score)

    // Critical: XSTO must rank strictly above STOXX LIMITED
    #expect(xsto!.score > stoxxLimited!.score)

    // NASDAQ STOCKHOLM AB — if it matches, XSTO must still rank higher
    if let nasdaq = nasdaqStockholm {
        #expect(xsto!.score > nasdaq.score)
    }
}

@Test func marketPickerXSTOvsSTOXUsingRankHelper() {
    // End-to-end ranking test using the rank helper, confirming XSTO sorts first
    let config = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))
    let results = rank("xsto", against: [
        "STOX",
        "STOXX LIMITED",
        "XSTO",
        "NASDAQ STOCKHOLM AB"
    ], config: config)

    // XSTO should be first (exact match, score 1.0)
    #expect(results.first?.candidate == "XSTO")
    #expect(results.first?.score == 1.0)
}
