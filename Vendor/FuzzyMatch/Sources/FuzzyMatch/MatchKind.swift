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

/// The kind of match that was found.
///
/// `MatchKind` indicates where in the candidate string the query matched.
/// This information is useful for:
/// - Highlighting the matched portion in UI
/// - Applying different sorting strategies
/// - Understanding why a candidate matched
///
/// ## Overview
///
/// | Kind | Description | Example Query | Example Candidate |
/// |------|-------------|---------------|-------------------|
/// | `.exact` | Query equals candidate | "user" | "User" |
/// | `.prefix` | Query matches start | "get" | "getUserById" |
/// | `.substring` | Query matches middle | "user" | "getCurrentUser" |
/// | `.acronym` | Query matches word initials | "icag" | "International Consolidated Airlines Group" |
/// | `.alignment` | Smith-Waterman local alignment | "gubi" | "getUserById" |
///
/// ## Scoring Impact
///
/// In **edit distance mode**, match kinds affect the final score through ``EditDistanceConfig`` weights:
/// - Prefix matches are multiplied by ``EditDistanceConfig/prefixWeight`` (default 1.5)
/// - Substring matches are multiplied by ``EditDistanceConfig/substringWeight`` (default 1.0)
/// - Acronym matches are multiplied by ``EditDistanceConfig/acronymWeight`` (default 1.0)
/// - Exact matches always have score 1.0
///
/// In **Smith-Waterman mode**, all non-exact, non-acronym matches return as `.alignment`.
/// The score is derived from the DP alignment quality normalized to [0, 1].
///
/// ## Example
///
/// ```swift
/// let matcher = FuzzyMatcher()
/// var buffer = matcher.makeBuffer()
///
/// // Exact match
/// let exact = matcher.score("User", against: matcher.prepare("user"), buffer: &buffer)
/// print(exact?.kind)  // .exact
///
/// // Prefix match
/// let prefix = matcher.score("getUserById", against: matcher.prepare("get"), buffer: &buffer)
/// print(prefix?.kind)  // .prefix
///
/// // Substring match
/// let substring = matcher.score("getCurrentUser", against: matcher.prepare("user"), buffer: &buffer)
/// print(substring?.kind)  // .substring
/// ```
public enum MatchKind: Sendable, Hashable, CaseIterable, Codable, CustomStringConvertible {
    /// An exact match where query equals candidate (case-insensitive).
    ///
    /// This is the highest-quality match type. The score is always 1.0.
    ///
    /// Example: Query "user" matches candidate "User" or "USER" exactly.
    case exact

    /// Query matches the beginning of candidate with possible edits.
    ///
    /// Prefix matches are preferred for code search because users often
    /// type the beginning of identifiers. The score is boosted by
    /// ``EditDistanceConfig/prefixWeight``.
    ///
    /// Example: Query "get" matches candidate "getUserById".
    case prefix

    /// Query matches somewhere within the candidate.
    ///
    /// Substring matches find the query anywhere in the candidate,
    /// not just at the beginning. The score is multiplied by
    /// ``EditDistanceConfig/substringWeight``.
    ///
    /// Example: Query "user" matches candidate "getCurrentUser".
    case substring

    /// Query matches the word-initial characters of the candidate.
    ///
    /// Acronym matches occur when each query character matches the first
    /// character of successive words in the candidate. The score is multiplied
    /// by ``EditDistanceConfig/acronymWeight``.
    ///
    /// Example: Query "icag" matches candidate "International Consolidated Airlines Group".
    case acronym

    /// Query matched via Smith-Waterman local alignment.
    ///
    /// Alignment matches are produced when using ``MatchingAlgorithm/smithWaterman(_:)`` mode.
    /// The score is derived from a single DP pass that finds the optimal local alignment
    /// of query characters within the candidate, with bonuses for word boundaries,
    /// camelCase transitions, and consecutive matches.
    ///
    /// Example: Query "gubi" matching "getUserById" via alignment scoring.
    case alignment

    /// A textual representation of the match kind.
    public var description: String {
        switch self {
        case .exact: "exact"
        case .prefix: "prefix"
        case .substring: "substring"
        case .acronym: "acronym"
        case .alignment: "alignment"
        }
    }
}
