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

/// Configuration for the Smith-Waterman matching algorithm.
///
/// Controls integer scoring constants used in the Smith-Waterman local alignment DP.
/// All values are integers — floating-point arithmetic is avoided in the inner loop.
/// The raw integer score is normalized to 0.0–1.0 after the DP completes.
///
/// ## Scoring Constants
///
/// | Parameter | Default | Description |
/// |-----------|---------|-------------|
/// | `scoreMatch` | 16 | Points awarded for each matched character |
/// | `penaltyGapStart` | 3 | Penalty for starting a gap (unmatched candidate chars) |
/// | `penaltyGapExtend` | 1 | Penalty for each additional gap character |
/// | `bonusConsecutive` | 4 | Bonus for consecutive matched characters |
/// | `bonusBoundary` | 8 | Bonus for matching at a word boundary |
/// | `bonusBoundaryWhitespace` | 10 | Bonus for matching after whitespace |
/// | `bonusBoundaryDelimiter` | 9 | Bonus for matching after a delimiter |
/// | `bonusCamelCase` | 5 | Bonus for matching at a camelCase transition |
/// | `bonusFirstCharMultiplier` | 2 | Multiplier applied to the first matched character's bonus |
/// | `splitSpaces` | true | Split multi-word queries into independent atoms |
///
/// ## Example
///
/// ```swift
/// // Use defaults
/// let config = SmithWatermanConfig.default
///
/// // Custom tuning
/// let custom = SmithWatermanConfig(
///     scoreMatch: 20,
///     penaltyGapStart: 4,
///     penaltyGapExtend: 2,
///     bonusConsecutive: 5,
///     bonusBoundary: 10,
///     bonusCamelCase: 6,
///     bonusFirstCharMultiplier: 3
/// )
/// ```
public struct SmithWatermanConfig: Sendable, Equatable, Codable {
    /// Points awarded for each character in the query that matches a character in the candidate.
    public var scoreMatch: Int

    /// Penalty for starting a new gap (unmatched candidate characters between matches).
    public var penaltyGapStart: Int

    /// Penalty for each additional character in an existing gap.
    public var penaltyGapExtend: Int

    /// Bonus for consecutive matched characters (no gap between them).
    public var bonusConsecutive: Int

    /// Bonus for matching at a word boundary (after non-word characters like underscore, hyphen, dot).
    public var bonusBoundary: Int

    /// Bonus for matching after whitespace (space, tab, newline).
    ///
    /// Whitespace boundaries are the strongest boundary type, reflecting that
    /// word separators in natural text are highly significant for matching.
    /// Also applied to the first character of the candidate (position 0).
    public var bonusBoundaryWhitespace: Int

    /// Bonus for matching after a delimiter character (`/`, `:`, `;`, `|`).
    ///
    /// Delimiter boundaries are slightly weaker than whitespace but stronger
    /// than general non-word boundaries.
    public var bonusBoundaryDelimiter: Int

    /// Bonus for matching at a camelCase transition (lowercase → uppercase) or digit transition.
    public var bonusCamelCase: Int

    /// Multiplier applied to the first matched character's boundary/camelCase bonus.
    public var bonusFirstCharMultiplier: Int

    /// Whether to split multi-word queries on spaces into independent atoms.
    ///
    /// When `true` (default), a query like `"johnson johnson"` is split into two
    /// atoms (`"johnson"`, `"johnson"`) that are scored independently against the
    /// candidate with AND semantics — all atoms must match for a result.
    /// This matches the behavior of nucleo and fzf.
    ///
    /// When `false`, the query is treated as a single monolithic alignment,
    /// which can cause failures when one word contains a typo.
    public var splitSpaces: Bool

    /// The default Smith-Waterman configuration with nucleo-inspired scoring constants.
    public static let `default` = Self(
        scoreMatch: 16,
        penaltyGapStart: 3,
        penaltyGapExtend: 1,
        bonusConsecutive: 4,
        bonusBoundary: 8,
        bonusBoundaryWhitespace: 10,
        bonusBoundaryDelimiter: 9,
        bonusCamelCase: 5,
        bonusFirstCharMultiplier: 2
    )

    /// Creates a new Smith-Waterman configuration.
    ///
    /// - Parameters:
    ///   - scoreMatch: Points per matched character. Default is `16`.
    ///   - penaltyGapStart: Penalty for starting a gap. Default is `3`.
    ///   - penaltyGapExtend: Penalty per additional gap character. Default is `1`.
    ///   - bonusConsecutive: Bonus for consecutive matches. Default is `4`.
    ///   - bonusBoundary: Bonus for word boundary matches. Default is `8`.
    ///   - bonusBoundaryWhitespace: Bonus for matches after whitespace. Default is `10`.
    ///   - bonusBoundaryDelimiter: Bonus for matches after delimiters. Default is `9`.
    ///   - bonusCamelCase: Bonus for camelCase/digit transition matches. Default is `5`.
    ///   - bonusFirstCharMultiplier: First character bonus multiplier. Default is `2`.
    ///   - splitSpaces: Whether to split multi-word queries into independent atoms. Default is `true`.
    public init(
        scoreMatch: Int = 16,
        penaltyGapStart: Int = 3,
        penaltyGapExtend: Int = 1,
        bonusConsecutive: Int = 4,
        bonusBoundary: Int = 8,
        bonusBoundaryWhitespace: Int = 10,
        bonusBoundaryDelimiter: Int = 9,
        bonusCamelCase: Int = 5,
        bonusFirstCharMultiplier: Int = 2,
        splitSpaces: Bool = true
    ) {
        self.scoreMatch = scoreMatch
        self.penaltyGapStart = penaltyGapStart
        self.penaltyGapExtend = penaltyGapExtend
        self.bonusConsecutive = bonusConsecutive
        self.bonusBoundary = bonusBoundary
        self.bonusBoundaryWhitespace = bonusBoundaryWhitespace
        self.bonusBoundaryDelimiter = bonusBoundaryDelimiter
        self.bonusCamelCase = bonusCamelCase
        self.bonusFirstCharMultiplier = bonusFirstCharMultiplier
        self.splitSpaces = splitSpaces
    }
}

extension SmithWatermanConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "SmithWatermanConfig(match: \(scoreMatch), gapStart: \(penaltyGapStart), gapExtend: \(penaltyGapExtend), consecutive: \(bonusConsecutive), boundary: \(bonusBoundary), whitespace: \(bonusBoundaryWhitespace), delimiter: \(bonusBoundaryDelimiter), camelCase: \(bonusCamelCase), firstChar: \(bonusFirstCharMultiplier)x, split: \(splitSpaces))"
    }
}
