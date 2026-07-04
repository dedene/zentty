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

/// A scored match result containing the score and match kind.
///
/// `ScoredMatch` is returned by ``FuzzyMatcher/score(_:against:buffer:)`` when
/// a candidate successfully matches the query. It contains both the numeric score
/// and the type of match that was found.
///
/// ## Overview
///
/// The score is a value between 0.0 and 1.0:
/// - `1.0`: Perfect match (exact or very close)
/// - `0.7-0.99`: Good match with minor differences
/// - `0.3-0.69`: Acceptable match with notable differences
/// - Below `minScore`: Not returned (filtered out)
///
/// ## Example
///
/// ```swift
/// let matcher = FuzzyMatcher()
/// let query = matcher.prepare("usr")
/// var buffer = matcher.makeBuffer()
///
/// if let match = matcher.score("user", against: query, buffer: &buffer) {
///     print("Score: \(match.score)")      // e.g., 0.75
///     print("Kind: \(match.kind)")   // .prefix
///
///     switch match.kind {
///     case .exact:
///         print("Exact match!")
///     case .prefix:
///         print("Matched at the beginning")
///     case .substring:
///         print("Matched somewhere in the middle")
///     case .acronym:
///         print("Matched word initials")
///     case .alignment:
///         print("Matched via local alignment")
///     }
/// }
/// ```
///
/// ## Sorting Results
///
/// `ScoredMatch` conforms to `Comparable`, so you can sort results by score:
///
/// ```swift
/// let results = matcher.topMatches(candidates, against: query)
/// // Results are sorted highest score first
/// ```
public struct ScoredMatch: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The match score between 0.0 (worst) and 1.0 (best).
    ///
    /// In **edit distance** mode, the score is derived from the Damerau-Levenshtein distance:
    /// - Base score: `1.0 - (editDistance / queryLength)`
    /// - Weighted by ``EditDistanceConfig/prefixWeight`` or ``EditDistanceConfig/substringWeight``
    /// - Enhanced with position-based bonuses (word boundaries, consecutive matches)
    ///
    /// In **Smith-Waterman** mode, the score is derived from the local alignment DP:
    /// - Raw integer score from matched characters, boundary bonuses, and gap penalties
    /// - Normalized to 0.0–1.0 against a theoretical maximum
    ///
    /// In both modes, an exact match always has score 1.0.
    public let score: Double

    /// The kind of match that was found.
    ///
    /// Indicates where in the candidate the query matched:
    /// - `.exact`: Query equals candidate (case-insensitive)
    /// - `.prefix`: Query matches the beginning of candidate (edit distance mode)
    /// - `.substring`: Query matches somewhere within candidate (edit distance mode)
    /// - `.acronym`: Query matches word-initial characters (both modes)
    /// - `.alignment`: Query matched via local alignment (Smith-Waterman mode)
    ///
    /// See ``MatchKind`` for details.
    public let kind: MatchKind

    /// Creates a new scored match.
    ///
    /// - Parameters:
    ///   - score: The match score between 0.0 and 1.0.
    ///   - kind: The kind of match.
    public init(score: Double, kind: MatchKind) {
        self.score = score
        self.kind = kind
    }

    /// Compares two scored matches by their score.
    ///
    /// This enables sorting match results from lowest to highest score.
    /// For highest-first sorting, use `>` or `sorted(by: >)`.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side match.
    ///   - rhs: The right-hand side match.
    /// - Returns: `true` if `lhs.score < rhs.score`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.score < rhs.score
    }

    /// A textual representation of the scored match.
    public var description: String {
        "ScoredMatch(score: \(score), kind: \(kind))"
    }
}

/// A matched candidate paired with its score.
///
/// Returned by ``FuzzyMatcher/topMatches(_:against:limit:)-(_,FuzzyQuery,_)`` and
/// ``FuzzyMatcher/matches(_:against:)-(_,FuzzyQuery)``.
///
/// ## Example
///
/// ```swift
/// for result in matcher.topMatches(candidates, against: query) {
///     print("\(result.candidate): \(result.match.score)")
/// }
/// ```
public struct MatchResult: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The candidate string that matched.
    public let candidate: String

    /// The match score and kind.
    public let match: ScoredMatch

    /// Creates a new match result.
    ///
    /// - Parameters:
    ///   - candidate: The candidate string that matched.
    ///   - match: The scored match containing score and kind.
    public init(candidate: String, match: ScoredMatch) {
        self.candidate = candidate
        self.match = match
    }

    /// Compares two match results by their scores.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side result.
    ///   - rhs: The right-hand side result.
    /// - Returns: `true` if `lhs.match.score < rhs.match.score`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.match < rhs.match
    }

    /// A textual representation of the match result.
    public var description: String {
        "MatchResult(candidate: \"\(candidate)\", match: \(match))"
    }
}
