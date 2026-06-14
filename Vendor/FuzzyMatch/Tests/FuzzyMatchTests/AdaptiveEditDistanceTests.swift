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

// MARK: - Adaptive Edit Distance Tests
//
// These tests validate the effectiveMaxEditDistance formula:
//   min(config.maxEditDistance, max(1, (queryLength - 1) / 2))
//
// Expected progression with default maxEditDistance=2:
//   1 char → 1,  2 chars → 1,  3 chars → 1,
//   4 chars → 1,  5 chars → 2,  6 chars → 2

/// Helper to score a query against a candidate with an optional config.
private func score(
    _ query: String,
    against candidate: String,
    config: MatchConfig = MatchConfig()
) -> Double? {
    let matcher = FuzzyMatcher(config: config)
    let prepared = matcher.prepare(query)
    var buffer = matcher.makeBuffer()
    return matcher.score(candidate, against: prepared, buffer: &buffer)?.score
}

/// Helper to rank candidates by score (highest first), returning all matches.
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

// MARK: - Effective maxEditDistance Progression

@Test func effectiveMaxEditDistance_1char() {
    // 1 char: max(1, (1-1)/2) = max(1, 0) = 1 → allows 1 edit
    let exact = score("c", against: "c")
    #expect(exact != nil)
    #expect(exact == 1.0)

    // "c" as prefix of "cat" should match
    let prefix = score("c", against: "cat")
    #expect(prefix != nil, "'c' should match 'cat' as prefix")
}

@Test func effectiveMaxEditDistance_2chars() {
    // 2 chars: max(1, (2-1)/2) = max(1, 0) = 1 → allows 1 edit
    let exact = score("co", against: "co")
    #expect(exact == 1.0)

    // 1 edit: "co" → "oc" (transposition, all chars present)
    let oneEdit = score("co", against: "oc")
    #expect(oneEdit != nil, "'co' should match 'oc' with 1 transposition")
}

@Test func effectiveMaxEditDistance_3chars() {
    // 3 chars: max(1, (3-1)/2) = max(1, 1) = 1 → allows 1 edit
    let exact = score("cov", against: "cov")
    #expect(exact == 1.0)

    // 1 edit: "cov" → "ocv" (transposition) — candidate still has all query chars c,o,v
    let oneEdit = score("cov", against: "ocv")
    #expect(oneEdit != nil, "'cov' should match 'ocv' with 1 transposition")

    // "cov" as prefix of "covestro" should match well
    let prefix = score("cov", against: "covestro")
    #expect(prefix != nil, "'cov' should match 'covestro' as prefix")

    // 3 edits should NOT match
    let threeEdits = score("cov", against: "xyz")
    #expect(threeEdits == nil, "'cov' should NOT match 'xyz' (3 edits)")
}

@Test func effectiveMaxEditDistance_4chars_staysAt1() {
    // 4 chars: max(1, (4-1)/2) = max(1, 1) = 1 → allows only 1 edit
    // This is the key fix: was previously 2, now 1
    let exact = score("cove", against: "cove")
    #expect(exact == 1.0)

    // 1 edit should still match — "cove" → "coev" (transposition, all chars present)
    let oneEdit = score("cove", against: "coev")
    #expect(oneEdit != nil, "'cove' should match 'coev' with 1 transposition")

    // 2 edits should NOT match at 4 chars (this is the fix!)
    // "cove" → "voce" has edit distance 2 (needs 2 substitutions or 1 transposition + 1 sub)
    // and all query chars c,o,v,e are present in "voce"
    let twoEdits = score("cove", against: "voce")
    #expect(twoEdits == nil, "'cove' should NOT match 'voce' with 2 edits (maxEdit=1 at 4 chars)")
}

@Test func effectiveMaxEditDistance_5chars_jumpsTo2() {
    // 5 chars: max(1, (5-1)/2) = max(1, 2) = 2 → allows 2 edits
    let exact = score("coves", against: "coves")
    #expect(exact == 1.0)

    // 2 edits should now match at 5 chars
    // "coves" → "voces" has all chars c,o,v,e,s and edit distance 2
    let twoEdits = score("coves", against: "voces")
    #expect(twoEdits != nil, "'coves' should match 'voces' with 2 edits (maxEdit=2 at 5 chars)")
}

@Test func effectiveMaxEditDistance_6chars() {
    // 6 chars: max(1, (6-1)/2) = max(1, 2) = 2 → allows 2 edits
    let exact = score("covest", against: "covest")
    #expect(exact == 1.0)

    // 2 edits should match — "covest" → "ocvets" (two transpositions, all chars present)
    let twoEdits = score("covest", against: "ocvets")
    #expect(twoEdits != nil, "'covest' should match 'ocvets' with 2 transpositions")
}

// MARK: - Realistic Instrument Search Scenarios

@Test func covestroProgressiveSearch_prefixMatchesThroughout() {
    // Simulates a user progressively typing "covestro" — every prefix should
    // match the candidate "Covestro AG" as a prefix match
    let candidate = "Covestro AG"
    for length in 1...8 {
        let query = String("covestro".prefix(length))
        let result = score(query, against: candidate)
        #expect(result != nil, "Query '\(query)' (\(length) chars) should match '\(candidate)'")
        if let result {
            #expect(result > 0.5, "Query '\(query)' should score well against '\(candidate)' (got \(result))")
        }
    }
}

@Test func coveQuery_prefersCovestroOverNoise() {
    // "cove" should rank "Covestro AG" highly, above unrelated strings
    // that might accidentally fuzzy-match
    let pickerConfig = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))
    let results = rank("cove", against: [
        "Covestro AG",
        "COVIVIO HOTELS",
        "COVIVIO",
        "Some Random String"
    ], config: pickerConfig)

    #expect(results.count >= 2)
    // Covestro should be in the results (exact prefix match on "cove")
    let covestro = results.first { $0.candidate == "Covestro AG" }
    #expect(covestro != nil, "'cove' should match 'Covestro AG'")
    #expect(covestro?.score ?? 0 > 0.8, "'cove' should score highly against 'Covestro AG'")
}

@Test func covQuery_matchesSymbolAndName() {
    // "cov" should match both symbols like "COV" and names like "Covestro"
    let results = rank("cov", against: [
        "COV",
        "COVH",
        "1COV",
        "Covestro AG",
        "COVIVIO"
    ])

    #expect(results.count >= 4)
    // Exact match "COV" should be first
    #expect(results[0].candidate == "COV")
}

@Test func fourCharQuery_rejectsHighEditDistanceCandidates() {
    // With the fix, 4-char queries only allow 1 edit
    // Note: char bitmask prefilter allows up to maxEditDistance missing char types

    // "cove" → "coev" is 1 transposition (all chars present) — should match
    let oneEdit = score("cove", against: "coev")
    #expect(oneEdit != nil, "'cove' should match 'coev' (1 transposition)")

    // "cove" → "voce" needs 2 edits (all chars present) — should be rejected
    let twoEdits = score("cove", against: "voce")
    #expect(twoEdits == nil, "'cove' should NOT match 'voce' (2 edits, maxEdit=1 at 4 chars)")
}

@Test func fiveCharQuery_acceptsTwoEditCandidates() {
    // At 5 chars, maxEdit goes to 2, so 2-edit candidates should match
    // "coves" → "voces" needs 2 edits and all chars c,o,v,e,s are present
    let twoEdits = score("coves", against: "voces")
    #expect(twoEdits != nil, "'coves' should match 'voces' (2 edits, maxEdit=2 at 5 chars)")
}

// MARK: - Picker Config (Strong Prefix Preference)

@Test func pickerConfig_prefixDominatesForShortQueries() {
    // With picker config (prefixWeight: 4.0, substringWeight: 0.5),
    // prefix matches should strongly dominate
    let pickerConfig = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))

    let results = rank("cov", against: [
        "Covestro AG",       // prefix match
        "Discovery Corp",    // "cov" appears as substring in "Discovery"... no
        "RECOVERY LTD"      // "cov" appears as substring in "reCOVery"
    ], config: pickerConfig)

    if let covestro = results.first(where: { $0.candidate == "Covestro AG" }),
       let recovery = results.first(where: { $0.candidate == "RECOVERY LTD" }) {
        #expect(covestro.score > recovery.score,
                "Prefix match 'Covestro AG' should outscore substring match 'RECOVERY LTD'")
    }
}

@Test func pickerConfig_coveStillMatchesCovestro() {
    let pickerConfig = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))
    let result = score("cove", against: "Covestro AG", config: pickerConfig)
    #expect(result != nil, "'cove' should match 'Covestro AG' with picker config")
    #expect(result ?? 0 > 0.9, "'cove' should score > 0.9 against 'Covestro AG' (exact prefix)")
}

// MARK: - Base58/Identifier Matching Behavior

@Test func shortQuery_doesNotOvermatchRandomStrings() {
    // Short queries should not produce high scores against random-looking
    // strings (simulating base58 identifiers)
    let pickerConfig = MatchConfig(algorithm: .editDistance(EditDistanceConfig(prefixWeight: 4.0, substringWeight: 0.5)))

    let randomStrings = [
        "EOBPM52609I484000P",
        "AOEOQ2609I201900C",
        "POZA12812F209000P",
        "DE0006062144"
    ]

    for candidate in randomStrings {
        let result = score("cove", against: candidate, config: pickerConfig)
        if let result {
            #expect(result < 0.5,
                    "'cove' should score low against random identifier '\(candidate)' (got \(result))")
        }
    }
}

// MARK: - Short Query Same-Length ED Restriction + Near-Exact Boost
//
// For queries <= 3 chars, ED-based typo matching (distance > 0) is only
// allowed when the candidate has the exact same length as the query.
// Same-length typo matches get a score boost (70% gap recovery) so they
// rank well above subsequence matches in long strings (e.g., base58 IDs).
// Exact matches (distance = 0) at any candidate length are unaffected.

@Test func shortQuery3_typoMatchesSameLength() {
    // "UDS" → "USD" is ED=1, both 3 chars → allowed and boosted
    let result = score("UDS", against: "USD")
    #expect(result != nil, "'UDS' should match 'USD' (ED=1, same length 3)")
    #expect(result! > 0.9, "'UDS' → 'USD' should score > 0.9 with same-length boost (got \(result!))")
}

@Test func shortQuery3_typoRejectsLonger() {
    // "UDS" vs "USD Fund" — ED=1 but 3 != 8 → blocked
    let result = score("UDS", against: "USD Fund")
    #expect(result == nil, "'UDS' should NOT match 'USD Fund' (3 != 8, typo blocked)")
}

@Test func shortQuery3_typoRejectsSlightlyLonger() {
    // "UDS" vs "USDA" — ED=1 but 3 != 4 → blocked
    let result = score("UDS", against: "USDA")
    #expect(result == nil, "'UDS' should NOT match 'USDA' (3 != 4, typo blocked)")
}

@Test func shortQuery3_exactPrefixStillWorks() {
    // "USD" vs "USD Fund" — ED=0, unaffected by restriction
    let result = score("USD", against: "USD Fund")
    #expect(result != nil, "'USD' should match 'USD Fund' (exact prefix, ED=0)")
}

@Test func shortQuery3_exactSubstringStillWorks() {
    // "USD" vs "EUR/USD" — ED=0, unaffected by restriction
    let result = score("USD", against: "EUR/USD")
    #expect(result != nil, "'USD' should match 'EUR/USD' (exact substring, ED=0)")
}

@Test func shortQuery4_notRestricted() {
    // 4-char queries are NOT subject to the same-length restriction
    let result = score("APEL", against: "AAPL")
    #expect(result != nil, "'APEL' should match 'AAPL' (4 chars, no restriction)")

    // 4-char typo can also match longer candidates
    let longer = score("APEL", against: "AAPL Inc")
    #expect(longer != nil, "'APEL' should match 'AAPL Inc' (4 chars, no restriction)")
}

@Test func shortQuery2_typoMatchesSameLength() {
    // "co" → "oc" is ED=1, both 2 chars → allowed and boosted
    let result = score("co", against: "oc")
    #expect(result != nil, "'co' should match 'oc' (ED=1, same length 2)")
    #expect(result! > 0.85, "'co' → 'oc' should score > 0.85 with boost (got \(result!))")
}

@Test func shortQuery2_typoRejectsLonger() {
    let result = score("oc", against: "XYZ")
    #expect(result == nil, "'oc' should NOT match 'XYZ' (no char overlap)")
}

@Test func shortQuery5_notRestricted() {
    // 5-char queries are NOT subject to the same-length restriction
    let result = score("coves", against: "voces")
    #expect(result != nil, "'coves' should match 'voces' (5 chars, no restriction)")
}

@Test func shortQuery_subsequenceUnaffected() {
    // Subsequence matching is not affected — "fb" matches "fooBar" via subsequence
    let result = score("fb", against: "fooBar")
    #expect(result != nil, "'fb' should match 'fooBar' via subsequence (unaffected)")
}

@Test func shortQuery_acronymUnaffected() {
    // Acronym matching is not affected — "bms" matches "Bristol-Myers Squibb"
    let result = score("bms", against: "Bristol-Myers Squibb")
    #expect(result != nil, "'bms' should match 'Bristol-Myers Squibb' via acronym (unaffected)")
}

@Test func shortQuery_currencyTypoRanking() {
    // "UDS" should rank "USD" first; "USD Fund" and "USDA" blocked by restriction
    let results = rank("UDS", against: [
        "USD",
        "USD Fund",
        "USDA",
        "UDS",          // exact match
        "Something Else"
    ])

    // "UDS" exact match should be present
    let udsExact = results.first { $0.candidate == "UDS" }
    #expect(udsExact != nil, "'UDS' should match itself exactly")

    // "USD" should match (same length, ED=1, boosted)
    let usd = results.first { $0.candidate == "USD" }
    #expect(usd != nil, "'UDS' should match 'USD' (same length typo)")

    // "USD Fund" and "USDA" should NOT match (restriction)
    let usdFund = results.first { $0.candidate == "USD Fund" }
    #expect(usdFund == nil, "'UDS' should NOT match 'USD Fund'")

    let usda = results.first { $0.candidate == "USDA" }
    #expect(usda == nil, "'UDS' should NOT match 'USDA'")
}

@Test func sameLengthBoost_scoresHigherThanUnboosted() {
    // Same-length transposition should score significantly higher than
    // the raw normalizedScore (which would be ~0.78 for 3-char ED=1)
    let result = score("UDS", against: "USD")
    #expect(result != nil)
    #expect(result! > 0.93, "Same-length boost should push score well above 0.78 (got \(result!))")
}
