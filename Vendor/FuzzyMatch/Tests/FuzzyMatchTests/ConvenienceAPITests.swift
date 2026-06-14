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

// MARK: - One-Shot score(_:against:) Tests

@Test func oneShotExactMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("User", against: "user")
    #expect(result != nil)
    #expect(result?.kind == .exact)
    #expect(result?.score == 1.0)
}

@Test func oneShotNilForNonMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("abc", against: "xyz")
    #expect(result == nil)
}

@Test func oneShotPrefixMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("getUserById", against: "get")
    #expect(result != nil)
    #expect(result?.kind == .prefix)
}

@Test func oneShotSubstringMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("getCurrentUser", against: "user")
    #expect(result != nil)
}

@Test func oneShotAcronymMatch() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("International Consolidated Airlines Group", against: "icag")
    #expect(result != nil)
    #expect(result?.kind == .acronym)
}

@Test func oneShotEmptyQuery() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("anything", against: "")
    #expect(result != nil)
    #expect(result?.score == 1.0)
    #expect(result?.kind == .exact)
}

@Test func oneShotEmptyCandidate() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("", against: "test")
    #expect(result == nil)
}

@Test func oneShotSingleCharQuery() {
    let matcher = FuzzyMatcher()
    let result = matcher.score("apple", against: "a")
    #expect(result != nil)
    #expect(result?.kind == .prefix)
}

@Test func oneShotWithCustomConfig() {
    let config = MatchConfig(minScore: 0.8, algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1)))
    let matcher = FuzzyMatcher(config: config)
    // "usr" vs "user" requires 1 edit — should pass maxEditDistance=1
    let result = matcher.score("user", against: "usr")
    // minScore=0.8 may filter this out depending on scoring — just verify it doesn't crash
    // and respects the config
    if let result = result {
        #expect(result.score >= 0.8)
    }
}

// MARK: - One-Shot Equivalence with High-Performance API

@Test func oneShotEquivalentToBufferAPI() {
    let matcher = FuzzyMatcher()
    let candidates = ["getUserById", "setUser", "fetchData", "configManager"]

    for candidate in candidates {
        let oneShot = matcher.score(candidate, against: "user")

        let query = matcher.prepare("user")
        var buffer = matcher.makeBuffer()
        let buffered = matcher.score(candidate, against: query, buffer: &buffer)

        #expect(oneShot?.score == buffered?.score)
        #expect(oneShot?.kind == buffered?.kind)
    }
}

@Test func oneShotEquivalenceAcrossMatchKinds() {
    let matcher = FuzzyMatcher()

    // Cover all match kinds: exact, prefix, substring, acronym, nil
    let cases: [(candidate: String, query: String)] = [
        ("User", "user"),                                       // exact
        ("getUserById", "get"),                                 // prefix
        ("getCurrentUser", "user"),                             // substring
        ("International Consolidated Airlines Group", "icag"),  // acronym
        ("abc", "xyz"),                                         // nil
        ("a", "a"),                                             // exact single char
        ("apple", "apl"),                                       // prefix with edit
        ("Bristol-Myers Squibb", "bms")                        // acronym
    ]

    for (candidate, queryStr) in cases {
        let oneShot = matcher.score(candidate, against: queryStr)

        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let buffered = matcher.score(candidate, against: query, buffer: &buffer)

        #expect(oneShot?.score == buffered?.score,
                "Score mismatch for \(candidate)/\(queryStr): oneShot=\(String(describing: oneShot?.score)) buffered=\(String(describing: buffered?.score))")
        #expect(oneShot?.kind == buffered?.kind,
                "Kind mismatch for \(candidate)/\(queryStr): oneShot=\(String(describing: oneShot?.kind)) buffered=\(String(describing: buffered?.kind))")
    }
}

@Test func oneShotEquivalenceWithTypos() {
    let matcher = FuzzyMatcher()

    let cases: [(candidate: String, query: String)] = [
        ("Goldman Sachs", "Goldamn"),
        ("Boeing", "Voeing"),
        ("Blackstone Inc", "blakstone"),
        ("Mastercard", "Mastecard")
    ]

    for (candidate, queryStr) in cases {
        let oneShot = matcher.score(candidate, against: queryStr)

        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let buffered = matcher.score(candidate, against: query, buffer: &buffer)

        #expect(oneShot?.score == buffered?.score,
                "Score mismatch for \(candidate)/\(queryStr)")
        #expect(oneShot?.kind == buffered?.kind,
                "Kind mismatch for \(candidate)/\(queryStr)")
    }
}

// MARK: - topMatches Tests

@Test func topMatchesReturnsCorrectCount() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")
    let candidates = ["getUserById", "setUser", "userService", "fetchData", "currentUser"]

    let results = matcher.topMatches(candidates, against: query, limit: 3)
    #expect(results.count == 3)
}

@Test func topMatchesSortedByScoreDescending() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")
    let candidates = ["getUserById", "setUser", "userService", "fetchData", "currentUser"]

    let results = matcher.topMatches(candidates, against: query, limit: 10)
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

@Test func topMatchesRespectsLimit() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    let candidates = (0..<20).map { "a\($0)item" }

    let results = matcher.topMatches(candidates, against: query, limit: 5)
    #expect(results.count == 5)
}

@Test func topMatchesDefaultLimitIs10() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("a")
    let candidates = (0..<20).map { "a\($0)item" }

    let results = matcher.topMatches(candidates, against: query)
    #expect(results.count == 10)
}

@Test func topMatchesEmptyWhenNoMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("xyz")
    let candidates = ["abc", "def", "ghi"]

    let results = matcher.topMatches(candidates, against: query, limit: 5)
    #expect(results.isEmpty)
}

@Test func topMatchesFewerThanLimit() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")
    let candidates = ["user", "xyz"]

    let results = matcher.topMatches(candidates, against: query, limit: 10)
    #expect(results.count == 1)
    #expect(results[0].candidate == "user")
}

@Test func topMatchesLimitOne() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("config")
    let candidates = ["appConfig", "configManager", "userConfig"]

    let results = matcher.topMatches(candidates, against: query, limit: 1)
    #expect(results.count == 1)
    // The single result should be the highest-scoring candidate
    let all = matcher.matches(candidates, against: query)
    #expect(results[0].candidate == all[0].candidate)
    #expect(results[0].match.score == all[0].match.score)
}

@Test func topMatchesEmptyInput() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    let results = matcher.topMatches([] as [String], against: query, limit: 5)
    #expect(results.isEmpty)
}

@Test func topMatchesSingleCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")

    let matching = matcher.topMatches(["user"], against: query, limit: 10)
    #expect(matching.count == 1)
    #expect(matching[0].candidate == "user")

    let nonMatching = matcher.topMatches(["xyz"], against: query, limit: 10)
    #expect(nonMatching.isEmpty)
}

@Test func topMatchesKeepsHighestScores() {
    // Verify that when more candidates match than the limit allows,
    // the returned results are truly the highest-scoring ones
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("get")
    let candidates = [
        "get",           // exact — highest score
        "getUser",       // prefix
        "getConfig",     // prefix
        "widget",        // substring (weaker)
        "budgetTracker" // substring (weaker)
    ]

    let top2 = matcher.topMatches(candidates, against: query, limit: 2)
    let all = matcher.matches(candidates, against: query)

    #expect(top2.count == 2)
    // The top-2 should match the first 2 from the full sorted list
    #expect(top2[0].candidate == all[0].candidate)
    #expect(top2[0].match.score == all[0].match.score)
    #expect(top2[1].candidate == all[1].candidate)
    #expect(top2[1].match.score == all[1].match.score)
}

// MARK: - topMatches Equivalence with High-Performance API

@Test func topMatchesEquivalentToManualSort() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("config")
    let candidates = [
        "appConfig", "configManager", "database", "userConfig",
        "systemConfiguration", "settings", "configPath", "reconfigure"
    ]

    let convenience = matcher.topMatches(candidates, against: query, limit: 3)

    // Manual high-performance approach
    var buffer = matcher.makeBuffer()
    var manual: [(String, ScoredMatch)] = []
    for candidate in candidates {
        if let match = matcher.score(candidate, against: query, buffer: &buffer) {
            manual.append((candidate, match))
        }
    }
    manual.sort { $0.1.score > $1.1.score }
    let manualTop3 = Array(manual.prefix(3))

    #expect(convenience.count == manualTop3.count)
    for i in 0..<convenience.count {
        #expect(convenience[i].candidate == manualTop3[i].0,
                "Candidate mismatch at index \(i)")
        #expect(convenience[i].match.score == manualTop3[i].1.score,
                "Score mismatch at index \(i)")
    }
}

// MARK: - matches Tests

@Test func matchesReturnsAllMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("config")
    let candidates = ["appConfig", "configManager", "database", "userConfig"]

    let results = matcher.matches(candidates, against: query)
    #expect(results.count == 3) // database shouldn't match
    let names = results.map { $0.candidate }
    #expect(names.contains("appConfig"))
    #expect(names.contains("configManager"))
    #expect(names.contains("userConfig"))
}

@Test func matchesEmptyForNoMatches() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("zzz")
    let candidates = ["abc", "def"]

    let results = matcher.matches(candidates, against: query)
    #expect(results.isEmpty)
}

@Test func matchesSortedByScoreDescending() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("get")
    let candidates = ["get", "getUser", "widget", "getConfig"]

    let results = matcher.matches(candidates, against: query)
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

@Test func matchesEmptyInput() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("test")
    let results = matcher.matches([] as [String], against: query)
    #expect(results.isEmpty)
}

@Test func matchesSingleCandidate() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")

    let matching = matcher.matches(["user"], against: query)
    #expect(matching.count == 1)
    #expect(matching[0].candidate == "user")
    #expect(matching[0].match.kind == .exact)

    let nonMatching = matcher.matches(["xyz"], against: query)
    #expect(nonMatching.isEmpty)
}

@Test func matchesLargeInput() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("item")
    // 500 candidates, all matching
    let candidates = (0..<500).map { "item\($0)_data" }

    let results = matcher.matches(candidates, against: query)
    #expect(results.count == 500)
    // Verify sorted
    for i in 1..<results.count {
        #expect(results[i - 1].match.score >= results[i].match.score)
    }
}

// MARK: - matches Equivalence with High-Performance API

@Test func matchesEquivalentToManualCollectAndSort() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("get")
    let candidates = [
        "get", "getUser", "widget", "getConfig", "budgetTracker",
        "forgetting", "target", "gadget"
    ]

    let convenience = matcher.matches(candidates, against: query)

    // Manual high-performance approach
    var buffer = matcher.makeBuffer()
    var manual: [(String, ScoredMatch)] = []
    for candidate in candidates {
        if let match = matcher.score(candidate, against: query, buffer: &buffer) {
            manual.append((candidate, match))
        }
    }
    manual.sort { $0.1.score > $1.1.score }

    #expect(convenience.count == manual.count,
            "Count mismatch: convenience=\(convenience.count) manual=\(manual.count)")
    for i in 0..<convenience.count {
        #expect(convenience[i].candidate == manual[i].0,
                "Candidate mismatch at index \(i): \(convenience[i].candidate) vs \(manual[i].0)")
        #expect(convenience[i].match.score == manual[i].1.score,
                "Score mismatch at index \(i) for \(convenience[i].candidate)")
        #expect(convenience[i].match.kind == manual[i].1.kind,
                "Kind mismatch at index \(i) for \(convenience[i].candidate)")
    }
}

// MARK: - UTF-8 API Equivalence Tests

@Test func utf8APIEquivalentToStringAPI() {
    let matcher = FuzzyMatcher()

    // Cover all match kinds: exact, prefix, substring, acronym, nil
    let cases: [(candidate: String, query: String)] = [
        ("User", "user"),                                       // exact
        ("getUserById", "get"),                                 // prefix
        ("getCurrentUser", "user"),                             // substring
        ("International Consolidated Airlines Group", "icag"),  // acronym
        ("abc", "xyz"),                                         // nil
        ("a", "a"),                                             // exact single char
        ("apple", "apl"),                                       // prefix with edit
        ("Bristol-Myers Squibb", "bms")                        // acronym
    ]

    for (candidate, queryStr) in cases {
        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let stringResult = matcher.score(candidate, against: query, buffer: &buffer)

        var c = candidate
        let utf8Result = c.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }

        #expect(stringResult?.score == utf8Result?.score,
                "Score mismatch for \(candidate)/\(queryStr): string=\(String(describing: stringResult?.score)) utf8=\(String(describing: utf8Result?.score))")
        #expect(stringResult?.kind == utf8Result?.kind,
                "Kind mismatch for \(candidate)/\(queryStr): string=\(String(describing: stringResult?.kind)) utf8=\(String(describing: utf8Result?.kind))")
    }
}

@Test func utf8APIEquivalentWithTypos() {
    let matcher = FuzzyMatcher()

    let cases: [(candidate: String, query: String)] = [
        ("Goldman Sachs", "Goldamn"),
        ("Boeing", "Voeing"),
        ("Blackstone Inc", "blakstone"),
        ("Mastercard", "Mastecard")
    ]

    for (candidate, queryStr) in cases {
        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let stringResult = matcher.score(candidate, against: query, buffer: &buffer)

        var c = candidate
        let utf8Result = c.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }

        #expect(stringResult?.score == utf8Result?.score,
                "Score mismatch for \(candidate)/\(queryStr)")
        #expect(stringResult?.kind == utf8Result?.kind,
                "Kind mismatch for \(candidate)/\(queryStr)")
    }
}

@Test func utf8APIEquivalentSmithWaterman() {
    let matcher = FuzzyMatcher(config: .smithWaterman)

    let cases: [(candidate: String, query: String)] = [
        ("User", "user"),
        ("getUserById", "get"),
        ("getCurrentUser", "user"),
        ("International Consolidated Airlines Group", "icag"),
        ("abc", "xyz"),
        ("Bristol-Myers Squibb", "bms")
    ]

    for (candidate, queryStr) in cases {
        let query = matcher.prepare(queryStr)
        var buffer = matcher.makeBuffer()
        let stringResult = matcher.score(candidate, against: query, buffer: &buffer)

        var c = candidate
        let utf8Result = c.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }

        #expect(stringResult?.score == utf8Result?.score,
                "SW score mismatch for \(candidate)/\(queryStr)")
        #expect(stringResult?.kind == utf8Result?.kind,
                "SW kind mismatch for \(candidate)/\(queryStr)")
    }
}

@Test func utf8APIWithEmptyInput() {
    let matcher = FuzzyMatcher()

    // Empty query — should match with score 1.0
    do {
        let query = matcher.prepare("")
        var buffer = matcher.makeBuffer()
        var candidate = "anything"
        let result = candidate.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }
        #expect(result != nil)
        #expect(result?.score == 1.0)
        #expect(result?.kind == .exact)
    }

    // Empty candidate — should return nil
    do {
        let query = matcher.prepare("test")
        var buffer = matcher.makeBuffer()
        var candidate = ""
        let result = candidate.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }
        #expect(result == nil)
    }

    // Both empty — should match
    do {
        let query = matcher.prepare("")
        var buffer = matcher.makeBuffer()
        var candidate = ""
        let result = candidate.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }
        #expect(result != nil)
        #expect(result?.score == 1.0)
    }
}

@Test func utf8APIBufferReuse() {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("user")
    var buffer = matcher.makeBuffer()

    let candidates = ["getUserById", "setUser", "userService", "fetchData", "currentUser"]

    // Score all candidates twice and verify identical results
    var firstPass: [ScoredMatch?] = []
    for candidate in candidates {
        var c = candidate
        let result = c.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }
        firstPass.append(result)
    }

    var secondPass: [ScoredMatch?] = []
    for candidate in candidates {
        var c = candidate
        let result = c.withUTF8 { utf8 in
            matcher.score(utf8: utf8, against: query, buffer: &buffer)
        }
        secondPass.append(result)
    }

    for i in 0..<candidates.count {
        #expect(firstPass[i]?.score == secondPass[i]?.score,
                "Buffer reuse score mismatch for \(candidates[i])")
        #expect(firstPass[i]?.kind == secondPass[i]?.kind,
                "Buffer reuse kind mismatch for \(candidates[i])")
    }
}

// MARK: - Cross-method consistency

@Test func topMatchesSubsetOfMatches() {
    // topMatches(limit: N) should return the same candidates and scores
    // as the first N elements of matches()
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("app")
    let candidates = [
        "appDelegate", "application", "myApp", "wrapper",
        "disappear", "snapshot", "appConfig", "mappable"
    ]

    let all = matcher.matches(candidates, against: query)
    let top3 = matcher.topMatches(candidates, against: query, limit: 3)

    let allTop3 = Array(all.prefix(3))
    #expect(top3.count == allTop3.count)
    for i in 0..<top3.count {
        #expect(top3[i].candidate == allTop3[i].candidate,
                "Candidate mismatch at \(i): topMatches=\(top3[i].candidate) matches=\(allTop3[i].candidate)")
        #expect(top3[i].match.score == allTop3[i].match.score,
                "Score mismatch at \(i)")
    }
}

@Test func matchesCountMatchesTopMatchesUnlimited() {
    // matches() should return the same count as topMatches with a huge limit
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("data")
    let candidates = ["database", "metadata", "dataSource", "update", "xyz"]

    let all = matcher.matches(candidates, against: query)
    let topAll = matcher.topMatches(candidates, against: query, limit: 1_000)

    #expect(all.count == topAll.count)
}
