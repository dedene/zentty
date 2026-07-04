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

extension FuzzyMatcher {
    /// Scores a candidate against a query string in a single call.
    ///
    /// This is a convenience method that handles query preparation and buffer
    /// management internally. For scoring many candidates against the same query,
    /// prefer the ``prepare(_:)`` + ``score(_:against:buffer:)`` pattern instead.
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to match.
    ///   - query: The query string to match against.
    /// - Returns: A ``ScoredMatch`` if the candidate matches, or `nil`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// if let match = matcher.score("getUserById", against: "getUser") {
    ///     print("Score: \(match.score)")
    /// }
    /// ```
    public func score(_ candidate: String, against query: String) -> ScoredMatch? {
        let prepared = prepare(query)
        var buffer = makeBuffer()
        return score(candidate, against: prepared, buffer: &buffer)
    }

    /// Returns the top matches from a sequence of candidates, sorted by score descending.
    ///
    /// - Parameters:
    ///   - candidates: The candidates to search.
    ///   - query: A prepared query from ``prepare(_:)``.
    ///   - limit: Maximum number of results to return. Default is `10`.
    /// - Returns: An array of ``MatchResult`` sorted by score descending,
    ///   containing at most `limit` elements.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("user")
    /// let results = matcher.topMatches(
    ///     ["getUserById", "setUser", "fetchData", "userService"],
    ///     against: query,
    ///     limit: 3
    /// )
    /// for result in results {
    ///     print("\(result.candidate): \(result.match.score)")
    /// }
    /// ```
    public func topMatches(
        _ candidates: some Sequence<String>,
        against query: FuzzyQuery,
        limit: Int = 10
    ) -> [MatchResult] {
        var buffer = makeBuffer()
        var results: [MatchResult] = []
        results.reserveCapacity(limit)

        for candidate in candidates {
            guard let match = score(candidate, against: query, buffer: &buffer) else {
                continue
            }
            let result = MatchResult(candidate: candidate, match: match)
            if results.count < limit {
                results.append(result)
                if results.count == limit {
                    results.sort { $0.match.score > $1.match.score }
                }
            } else if match.score > results[results.count - 1].match.score {
                results[results.count - 1] = result
                results.sort { $0.match.score > $1.match.score }
            }
        }

        if results.count < limit {
            results.sort { $0.match.score > $1.match.score }
        }

        return results
    }

    /// Returns all matching candidates sorted by score descending.
    ///
    /// - Parameters:
    ///   - candidates: The candidates to search.
    ///   - query: A prepared query from ``prepare(_:)``.
    /// - Returns: An array of ``MatchResult`` sorted by score descending.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("config")
    /// let all = matcher.matches(
    ///     ["appConfig", "configManager", "database", "userConfig"],
    ///     against: query
    /// )
    /// // Returns matches for "appConfig", "configManager", "userConfig"
    /// ```
    public func matches(
        _ candidates: some Sequence<String>,
        against query: FuzzyQuery
    ) -> [MatchResult] {
        var buffer = makeBuffer()
        var results: [MatchResult] = []

        for candidate in candidates {
            if let match = score(candidate, against: query, buffer: &buffer) {
                results.append(MatchResult(candidate: candidate, match: match))
            }
        }

        results.sort { $0.match.score > $1.match.score }
        return results
    }

    /// Returns the top matches from a sequence of candidates, sorted by score descending.
    ///
    /// This is a convenience method that handles query preparation internally.
    /// For scoring many queries against the same candidates, prefer the
    /// ``prepare(_:)`` + ``topMatches(_:against:limit:)-(_,FuzzyQuery,_)`` pattern instead.
    ///
    /// - Parameters:
    ///   - candidates: The candidates to search.
    ///   - query: The query string to match against.
    ///   - limit: Maximum number of results to return. Default is `10`.
    /// - Returns: An array of ``MatchResult`` sorted by score descending,
    ///   containing at most `limit` elements.
    public func topMatches(
        _ candidates: some Sequence<String>,
        against query: String,
        limit: Int = 10
    ) -> [MatchResult] {
        topMatches(candidates, against: prepare(query), limit: limit)
    }

    /// Returns all matching candidates sorted by score descending.
    ///
    /// This is a convenience method that handles query preparation internally.
    /// For scoring many queries against the same candidates, prefer the
    /// ``prepare(_:)`` + ``matches(_:against:)-(_,FuzzyQuery)`` pattern instead.
    ///
    /// - Parameters:
    ///   - candidates: The candidates to search.
    ///   - query: The query string to match against.
    /// - Returns: An array of ``MatchResult`` sorted by score descending.
    public func matches(
        _ candidates: some Sequence<String>,
        against query: String
    ) -> [MatchResult] {
        matches(candidates, against: prepare(query))
    }
}
