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

/// The matching algorithm to use for scoring.
///
/// FuzzyMatch supports two fundamentally different matching approaches,
/// each with its own configuration:
///
/// - ``editDistance(_:)``: (Default) Penalty-driven scoring using Damerau-Levenshtein edit distance
///   with a multi-phase pipeline (exact → prefix → substring → subsequence → acronym).
///   Configure via ``EditDistanceConfig``.
/// - ``smithWaterman(_:)``: Bonus-driven scoring using a Smith-Waterman local alignment variant
///   where each matched character earns points, with rewards for word boundaries,
///   camelCase transitions, and consecutive runs. Configure via ``SmithWatermanConfig``.
///
/// ## Example
///
/// ```swift
/// // Default edit distance mode
/// let edMatcher = FuzzyMatcher()
///
/// // Smith-Waterman mode
/// let swMatcher = FuzzyMatcher(config: .smithWaterman)
///
/// // Custom edit distance
/// let custom = FuzzyMatcher(config: MatchConfig(
///     algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))
/// ))
///
/// // Custom Smith-Waterman
/// let customSW = FuzzyMatcher(config: MatchConfig(
///     algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 8))
/// ))
/// ```
public enum MatchingAlgorithm: Sendable, Equatable, Codable {
    /// Damerau-Levenshtein edit distance with multi-phase scoring pipeline.
    ///
    /// - Parameter config: Configuration for edit distance scoring.
    ///   Defaults to ``EditDistanceConfig/default``.
    case editDistance(EditDistanceConfig = .default)

    /// Smith-Waterman local alignment with bonus-driven scoring.
    ///
    /// - Parameter config: Configuration for Smith-Waterman scoring.
    ///   Defaults to ``SmithWatermanConfig/default``.
    case smithWaterman(SmithWatermanConfig = .default)

    private enum CodingKeys: String, CodingKey {
        case type, config
    }

    /// Decodes a matching algorithm from a keyed container with `type` and `config` fields.
    ///
    /// Expected JSON format:
    /// ```json
    /// { "type": "editDistance", "config": { ... } }
    /// { "type": "smithWaterman", "config": { ... } }
    /// ```
    ///
    /// - Throws: `DecodingError.dataCorruptedError` if the `type` value is not recognized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "editDistance":
            let config = try container.decode(EditDistanceConfig.self, forKey: .config)
            self = .editDistance(config)
        case "smithWaterman":
            let config = try container.decode(SmithWatermanConfig.self, forKey: .config)
            self = .smithWaterman(config)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown MatchingAlgorithm type: \(type)"
            )
        }
    }

    /// Encodes the matching algorithm into a keyed container with `type` and `config` fields.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .editDistance(let config):
            try container.encode("editDistance", forKey: .type)
            try container.encode(config, forKey: .config)
        case .smithWaterman(let config):
            try container.encode("smithWaterman", forKey: .type)
            try container.encode(config, forKey: .config)
        }
    }
}

/// Strategy for penalizing gaps between matched characters.
///
/// Gaps occur when query characters match non-consecutive positions in the candidate.
/// For example, query "ab" matching "aXXXb" has a gap of 3 characters.
///
/// ## Choosing a Gap Penalty Strategy
///
/// - Use ``affine(open:extend:)`` (default) for matching where starting a
///   gap is more expensive than continuing one. This encourages tighter matches.
/// - Use ``linear(perCharacter:)`` for simpler scoring where each gap character
///   costs the same amount.
/// - Use ``none`` to disable gap penalties entirely.
///
/// ## Example
///
/// ```swift
/// // Default affine model - starting gaps is expensive
/// let config = EditDistanceConfig(gapPenalty: .affine(open: 0.03, extend: 0.005))
///
/// // Simple linear model - each gap char costs 1%
/// let config2 = EditDistanceConfig(gapPenalty: .linear(perCharacter: 0.01))
///
/// // No gap penalty
/// let config3 = EditDistanceConfig(gapPenalty: .none)
/// ```
public enum GapPenalty: Sendable, Equatable, Codable {
    /// No penalty for gaps between matched characters.
    case none

    /// Linear gap penalty: each gap character costs the same.
    ///
    /// - Parameter perCharacter: Penalty subtracted from score per gap character.
    ///   Typical values: 0.005-0.02.
    ///
    /// ## Example
    /// ```swift
    /// // Query "ab" matching "aXXXb" (gap of 3)
    /// // Penalty: 3 * 0.01 = 0.03
    /// .linear(perCharacter: 0.01)
    /// ```
    case linear(perCharacter: Double)

    /// Affine gap penalty: starting a gap costs more than continuing one.
    ///
    /// This model encourages matches with fewer, longer gaps over many short gaps.
    /// The penalty for a gap of size N is: `open + (N - 1) * extend`
    ///
    /// - Parameters:
    ///   - open: Penalty for starting a new gap. Typical values: 0.02-0.05.
    ///   - extend: Penalty for each additional character in the gap. Typical values: 0.002-0.01.
    ///
    /// ## Example
    /// ```swift
    /// // Query "ab" matching "aXXXb" (gap of 3)
    /// // Penalty: 0.03 + (3-1) * 0.005 = 0.04
    /// .affine(open: 0.03, extend: 0.005)
    /// ```
    case affine(open: Double, extend: Double)

    /// The default gap penalty strategy: affine with open=0.03, extend=0.005.
    public static let `default`: GapPenalty = .affine(open: 0.03, extend: 0.005)

    private enum CodingKeys: String, CodingKey {
        case type, perCharacter, open, extend
    }

    /// Decodes a gap penalty from a keyed container with a `type` discriminator.
    ///
    /// Expected JSON format:
    /// ```json
    /// { "type": "none" }
    /// { "type": "linear", "perCharacter": 0.01 }
    /// { "type": "affine", "open": 0.03, "extend": 0.005 }
    /// ```
    ///
    /// - Throws: `DecodingError.dataCorruptedError` if the `type` value is not recognized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "none":
            self = .none
        case "linear":
            let perCharacter = try container.decode(Double.self, forKey: .perCharacter)
            self = .linear(perCharacter: perCharacter)
        case "affine":
            let open = try container.decode(Double.self, forKey: .open)
            let extend = try container.decode(Double.self, forKey: .extend)
            self = .affine(open: open, extend: extend)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown GapPenalty type: \(type)"
            )
        }
    }

    /// Encodes the gap penalty into a keyed container with a `type` discriminator.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .linear(let perCharacter):
            try container.encode("linear", forKey: .type)
            try container.encode(perCharacter, forKey: .perCharacter)
        case .affine(let open, let extend):
            try container.encode("affine", forKey: .type)
            try container.encode(open, forKey: .open)
            try container.encode(extend, forKey: .extend)
        }
    }
}

/// Configuration for the edit distance matching algorithm.
///
/// Controls the Damerau-Levenshtein edit distance pipeline, including how many
/// edits (typos) are tolerated, how prefix vs. substring matches are weighted,
/// scoring bonuses for word boundaries, consecutive matches, and early positions,
/// and gap penalties using either a simple linear model or an affine model.
///
/// ## Overview
///
/// The default configuration works well for most code identifier search scenarios,
/// providing intelligent ranking with bonuses for word boundary matches, consecutive
/// characters, and early match positions.
///
/// ## Common Use Cases
///
/// | Use Case | Suggested Configuration |
/// |----------|------------------------|
/// | Strict autocomplete | `maxEditDistance: 1` (with `minScore: 0.7` on `MatchConfig`) |
/// | Typo-tolerant search | `maxEditDistance: 3` |
/// | Prefix-focused | `prefixWeight: 2.0, substringWeight: 0.5` |
/// | Abbreviation matching | Increase `wordBoundaryBonus` to `0.15` |
/// | Favor early matches | Increase `firstMatchBonus` to `0.2` |
/// | Tight matches only | Use `.affine(open: 0.05, extend: 0.01)` |
/// | Pure edit distance | Set all bonuses to `0.0`, `gapPenalty: .none` |
///
/// ## Gap Penalty Strategies
///
/// Use the ``GapPenalty`` enum to choose how gaps are penalized:
///
/// - ``GapPenalty/affine(open:extend:)`` **(Default)**: Starting a gap is expensive,
///   continuing is cheaper. Best for code search where tight matches are preferred.
///
/// - ``GapPenalty/linear(perCharacter:)``: Each gap character costs the same.
///   Simpler model, good when gap size matters uniformly.
///
/// - ``GapPenalty/none``: No gap penalties. Useful for pure edit-distance matching.
///
/// ## Example
///
/// ```swift
/// // Default configuration - good for code identifier search
/// let defaultConfig = EditDistanceConfig()
///
/// // Strict autocomplete: few typos, prefer prefixes
/// let autocompleteConfig = EditDistanceConfig(
///     maxEditDistance: 1,
///     prefixWeight: 2.0,
///     substringWeight: 0.8
/// )
///
/// // Abbreviation-focused: reward word boundary matches heavily
/// let abbreviationConfig = EditDistanceConfig(
///     wordBoundaryBonus: 0.15,
///     consecutiveBonus: 0.03,
///     firstMatchBonus: 0.1
/// )
///
/// // Pure edit-distance scoring (no bonuses)
/// let pureEditDistanceConfig = EditDistanceConfig(
///     wordBoundaryBonus: 0.0,
///     consecutiveBonus: 0.0,
///     gapPenalty: .none,
///     firstMatchBonus: 0.0
/// )
/// ```
public struct EditDistanceConfig: Sendable, Equatable, Codable {
    /// Maximum allowed edit distance for a match to be considered valid.
    ///
    /// Edit distance is the minimum number of single-character edits (insertions,
    /// deletions, substitutions, or transpositions) needed to transform the query
    /// into the matched portion of the candidate.
    ///
    /// - Lower values (0-1): Strict matching, few typos allowed
    /// - Higher values (2-3): More lenient, tolerates more typos
    ///
    /// The default value of `2` balances typo tolerance with performance.
    /// For longer queries (≥ ``longQueryThreshold`` characters), the matcher
    /// automatically uses ``longQueryMaxEditDistance`` instead.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // maxEditDistance: 2
    /// // "usr" matches "user" (1 edit: insert 'e')
    /// // "teh" matches "the" (1 edit: transpose 'eh')
    /// // "abcd" does NOT match "xyz" (too many edits)
    /// ```
    public var maxEditDistance: Int

    /// Maximum allowed edit distance for queries with ``longQueryThreshold`` or more characters.
    ///
    /// Longer queries can tolerate more edits without degrading result quality,
    /// so this allows a higher ceiling for typo tolerance on longer search terms
    /// (e.g., "Johsnon Johnson" or "Proctre Gamble").
    ///
    /// - Default: `3`
    /// - Set equal to ``maxEditDistance`` to disable adaptive behavior.
    public var longQueryMaxEditDistance: Int

    /// Minimum query length (in UTF-8 bytes) at which ``longQueryMaxEditDistance`` takes effect.
    ///
    /// Queries shorter than this threshold use ``maxEditDistance``.
    ///
    /// - Default: `13` (one character longer than an ISIN code, so exact ISIN lookups
    ///   stay at the lower edit distance while longer natural-language queries benefit
    ///   from higher typo tolerance)
    public var longQueryThreshold: Int

    /// Weight multiplier applied to prefix matches.
    ///
    /// Prefix matches occur when the query matches the beginning of the candidate.
    /// A weight greater than 1.0 boosts prefix matches relative to substring matches.
    ///
    /// The score is calculated as: `max(0, 1.0 - (1.0 - baseScore) / prefixWeight)`.
    ///
    /// - `1.0`: No boost for prefix matches
    /// - `1.5`: Default, moderate prefix preference
    /// - `2.0`: Strong prefix preference
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Query "get" vs "getUserById" (prefix match)
    /// // With prefixWeight: 1.5 → boosted score
    /// // Query "get" vs "targetMethod" (substring match)
    /// // With substringWeight: 1.0 → base score
    /// ```
    public var prefixWeight: Double

    /// Weight multiplier applied to substring matches.
    ///
    /// Substring matches occur when the query matches somewhere within the candidate,
    /// but not at the beginning. This is typically set lower than ``prefixWeight``
    /// to prefer prefix matches.
    ///
    /// The score is calculated as: `max(0, 1.0 - (1.0 - baseScore) / substringWeight)`.
    ///
    /// - `0.5`: Significantly penalize non-prefix matches
    /// - `1.0`: Default, no penalty
    /// - Values > 1.0: Unusual, would boost substring over prefix
    public var substringWeight: Double

    /// Bonus multiplier for matches at word boundaries.
    ///
    /// Word boundaries occur at camelCase transitions, after underscores, after digits,
    /// and after non-alphanumeric characters. Matching at boundaries indicates the user
    /// is typing abbreviations (e.g., "gubi" for "getUserById").
    ///
    /// - `0.0`: No bonus for boundary matches
    /// - `0.1`: Default, 10% bonus per boundary match
    /// - Higher values: Stronger preference for boundary matches
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Query "gubi" matching "getUserById" at positions g, U, B, I
    /// // All 4 characters match at word boundaries
    /// // Bonus: 4 * 0.1 = 0.4 added to base score
    /// ```
    public var wordBoundaryBonus: Double

    /// Bonus multiplier for consecutive matching characters.
    ///
    /// When query characters match consecutive positions in the candidate,
    /// this bonus is added for each consecutive pair. This rewards matches
    /// where the query appears as a contiguous substring.
    ///
    /// - `0.0`: No bonus for consecutive matches
    /// - `0.05`: Default, 5% bonus per consecutive pair
    /// - Higher values: Stronger preference for contiguous matches
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Query "get" matching "getUserById" at positions 0, 1, 2
    /// // Two consecutive pairs: (0,1) and (1,2)
    /// // Bonus: 2 * 0.05 = 0.1 added to base score
    /// ```
    public var consecutiveBonus: Double

    /// Strategy for penalizing gaps between matched characters.
    ///
    /// Gaps occur when query characters match non-consecutive positions in the candidate.
    /// This penalty discourages matches where query characters are spread far apart.
    ///
    /// - ``GapPenalty/none``: No penalty for gaps
    /// - ``GapPenalty/linear(perCharacter:)``: Simple model where each gap char costs the same
    /// - ``GapPenalty/affine(open:extend:)``: Default. Starting gaps costs more than continuing
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default affine model (recommended for code search)
    /// let config1 = EditDistanceConfig(gapPenalty: .affine(open: 0.03, extend: 0.005))
    ///
    /// // Simple linear model
    /// let config2 = EditDistanceConfig(gapPenalty: .linear(perCharacter: 0.01))
    ///
    /// // Query "ui" matching "getUserById" at positions 4, 9
    /// // Gap of 4 characters between matches
    /// // Linear: 4 * 0.01 = 0.04 penalty
    /// // Affine: 0.03 + 3 * 0.005 = 0.045 penalty
    /// ```
    public var gapPenalty: GapPenalty

    /// Bonus applied based on how early the first match appears in the candidate.
    ///
    /// A match at position 0 gets the full bonus; the bonus decays linearly to zero
    /// at ``firstMatchBonusRange``. This encourages matches where the query aligns
    /// with the beginning of the candidate.
    ///
    /// - `0.0`: No bonus for early matches
    /// - `0.15`: Default, 15% bonus for position 0
    /// - `0.2-0.25`: Strong preference for early matches (good for file search)
    ///
    /// ## Ranking Impact
    ///
    /// This bonus helps rank "getUserInfo" higher than "debugUserInfo" when
    /// searching for "gui", because the match starts earlier in the string.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // With firstMatchBonus: 0.15, firstMatchBonusRange: 10
    /// //
    /// // Query "gui" matching "getUserInfo" at position 0
    /// // → Full bonus: 0.15 * (1 - 0/10) = 0.15
    /// //
    /// // Query "gui" matching "debugUserInfo" at position 5
    /// // → Partial bonus: 0.15 * (1 - 5/10) = 0.075
    /// //
    /// // Query "gui" matching "someLongPrefixUserInfo" at position 14
    /// // → No bonus (position >= firstMatchBonusRange)
    /// ```
    public var firstMatchBonus: Double

    /// Maximum position that still receives a (partial) first-match bonus.
    ///
    /// Matches starting beyond this position get no ``firstMatchBonus``.
    /// The bonus decays linearly from position 0 to this value.
    ///
    /// - `10`: Default, positions 0-9 receive partial bonus
    /// - Lower values: Stricter position requirement
    /// - Higher values: More lenient, bonus extends further into the string
    public var firstMatchBonusRange: Int

    /// Penalty per excess character when the candidate is longer than the query.
    ///
    /// For each character by which the candidate exceeds the query length, this
    /// value is subtracted from the score. Lower values reduce the disadvantage
    /// of matching inside long strings (e.g. full instrument names or ISINs).
    ///
    /// - `0.003`: Default, moderate penalty
    /// - `0.001`: Mild penalty (good for pickers with mixed-length fields)
    /// - `0.0`: No length penalty
    public var lengthPenalty: Double

    /// Weight multiplier applied to acronym matches.
    ///
    /// Acronym matches occur when the query matches word-initial characters of
    /// the candidate (e.g., "icag" matching "International Consolidated Airlines Group").
    ///
    /// - `1.0`: Default, no adjustment
    /// - `> 1.0`: Boost acronym matches
    /// - `< 1.0`: Reduce acronym match scores
    public var acronymWeight: Double

    /// The default edit distance configuration.
    public static let `default` = Self()

    /// A preset with scoring constants aligned to fzf's proven ratios.
    ///
    /// fzf uses: scoreMatch=16, boundary=8, consecutive=4, gapStart=-3, gapExtend=-1.
    /// These ratios are mapped to a 0.0-1.0 scale:
    /// - boundary/match = 8/16 = 0.5 → wordBoundaryBonus = 0.12
    /// - consecutive/match = 4/16 = 0.25 → consecutiveBonus = 0.06
    /// - gapStart/match = 3/16 = 0.1875 → gapOpen = 0.04
    /// - gapExtend/match = 1/16 = 0.0625 → gapExtend = 0.012
    public static let fzfAligned = Self(
        wordBoundaryBonus: 0.12,
        consecutiveBonus: 0.06,
        gapPenalty: .affine(open: 0.04, extend: 0.012)
    )

    /// Creates a new edit distance configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - maxEditDistance: Maximum allowed edit distance. Default is `2`.
    ///   - longQueryMaxEditDistance: Maximum edit distance for long queries. Default is `3`.
    ///   - longQueryThreshold: Query length at which `longQueryMaxEditDistance` takes effect. Default is `13`.
    ///   - prefixWeight: Weight for prefix matches. Default is `1.5`.
    ///   - substringWeight: Weight for substring matches. Default is `1.0`.
    ///   - wordBoundaryBonus: Bonus for matches at word boundaries. Default is `0.1`.
    ///   - consecutiveBonus: Bonus for consecutive character matches. Default is `0.05`.
    ///   - gapPenalty: Strategy for penalizing gaps. Default is `.affine(open: 0.03, extend: 0.005)`.
    ///   - firstMatchBonus: Bonus for early first-match position. Default is `0.15`.
    ///   - firstMatchBonusRange: Max position for first-match bonus. Default is `10`.
    ///   - lengthPenalty: Penalty per excess character in the candidate. Default is `0.003`.
    ///   - acronymWeight: Weight for acronym matches. Default is `1.0`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default configuration (includes scoring bonuses)
    /// let defaultConfig = EditDistanceConfig()
    ///
    /// // Custom configuration with stronger boundary preference
    /// let customConfig = EditDistanceConfig(
    ///     maxEditDistance: 1,
    ///     prefixWeight: 2.0,
    ///     substringWeight: 0.8,
    ///     wordBoundaryBonus: 0.15,
    ///     consecutiveBonus: 0.08,
    ///     gapPenalty: .linear(perCharacter: 0.02)
    /// )
    ///
    /// // Disable bonuses for pure edit-distance scoring
    /// let noBonusConfig = EditDistanceConfig(
    ///     wordBoundaryBonus: 0.0,
    ///     consecutiveBonus: 0.0,
    ///     gapPenalty: .none,
    ///     firstMatchBonus: 0.0
    /// )
    ///
    /// // Tighter matching: increase gap penalties
    /// let tightConfig = EditDistanceConfig(
    ///     gapPenalty: .affine(open: 0.05, extend: 0.01)
    /// )
    /// ```
    public init(
        maxEditDistance: Int = 2,
        longQueryMaxEditDistance: Int = 3,
        longQueryThreshold: Int = 13,
        prefixWeight: Double = 1.5,
        substringWeight: Double = 1.0,
        wordBoundaryBonus: Double = 0.1,
        consecutiveBonus: Double = 0.05,
        gapPenalty: GapPenalty = .default,
        firstMatchBonus: Double = 0.15,
        firstMatchBonusRange: Int = 10,
        lengthPenalty: Double = 0.003,
        acronymWeight: Double = 1.0
    ) {
        self.maxEditDistance = maxEditDistance
        self.longQueryMaxEditDistance = longQueryMaxEditDistance
        self.longQueryThreshold = longQueryThreshold
        self.prefixWeight = prefixWeight
        self.substringWeight = substringWeight
        self.wordBoundaryBonus = wordBoundaryBonus
        self.consecutiveBonus = consecutiveBonus
        self.gapPenalty = gapPenalty
        self.firstMatchBonus = firstMatchBonus
        self.firstMatchBonusRange = firstMatchBonusRange
        self.lengthPenalty = lengthPenalty
        self.acronymWeight = acronymWeight
    }
}

/// Configuration for fuzzy matching behavior.
///
/// `MatchConfig` controls how ``FuzzyMatcher`` evaluates candidates. It contains
/// the minimum score threshold (shared across all algorithms) and the matching
/// algorithm selection with its mode-specific configuration.
///
/// ## Overview
///
/// Choose a matching algorithm via ``algorithm``:
/// - ``MatchingAlgorithm/editDistance(_:)`` (default): Configure with ``EditDistanceConfig``
/// - ``MatchingAlgorithm/smithWaterman(_:)``: Configure with ``SmithWatermanConfig``
///
/// Only the parameters relevant to the selected algorithm are available,
/// making invalid configurations impossible.
///
/// ## Example
///
/// ```swift
/// // Default configuration - edit distance with standard settings
/// let defaultConfig = MatchConfig()
///
/// // Custom edit distance: strict autocomplete
/// let autocompleteConfig = MatchConfig(
///     minScore: 0.6,
///     algorithm: .editDistance(EditDistanceConfig(
///         maxEditDistance: 1,
///         prefixWeight: 2.0,
///         substringWeight: 0.8
///     ))
/// )
///
/// // Smith-Waterman mode with defaults
/// let swConfig = MatchConfig(algorithm: .smithWaterman())
///
/// // Smith-Waterman with custom tuning
/// let customSW = MatchConfig(
///     algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 8))
/// )
///
/// // Just adjust minScore (uses default edit distance)
/// let strictConfig = MatchConfig(minScore: 0.8)
///
/// let matcher = FuzzyMatcher(config: autocompleteConfig)
/// ```
public struct MatchConfig: Sendable, Equatable, Codable {
    /// Minimum score threshold (0.0 to 1.0) for a match to be returned.
    ///
    /// Candidates with scores below this threshold are rejected even if they
    /// pass the edit distance check. This filters out low-quality matches.
    ///
    /// - `0.0`: Accept any match within edit distance
    /// - `0.3`: Default, filters weak matches
    /// - `0.7`: Only high-quality matches
    /// - `1.0`: Only exact matches
    ///
    /// ## Example
    ///
    /// ```swift
    /// // With minScore: 0.5
    /// // Query "abc" vs "abcd" → score ~0.75 ✓ (passes)
    /// // Query "abc" vs "axbxcx" → score ~0.33 ✗ (rejected)
    /// ```
    public var minScore: Double

    /// The matching algorithm to use, with its mode-specific configuration.
    ///
    /// - ``MatchingAlgorithm/editDistance(_:)``: (Default) Multi-phase edit distance pipeline.
    ///   Configure edit distance parameters, scoring bonuses, and gap penalties via ``EditDistanceConfig``.
    /// - ``MatchingAlgorithm/smithWaterman(_:)``: Single-pass local alignment scoring.
    ///   Configure scoring constants via ``SmithWatermanConfig``.
    public var algorithm: MatchingAlgorithm

    /// The default configuration using edit distance matching.
    public static let editDistance = Self()

    /// A preset for Smith-Waterman local alignment matching.
    ///
    /// Uses the default ``SmithWatermanConfig`` scoring constants.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher(config: .smithWaterman)
    /// ```
    public static let smithWaterman = Self(algorithm: .smithWaterman())

    /// A preset with scoring constants aligned to fzf's proven ratios.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher(config: .fzfAligned)
    /// ```
    public static let fzfAligned = Self(algorithm: .editDistance(.fzfAligned))

    /// Creates a new match configuration.
    ///
    /// - Parameters:
    ///   - minScore: Minimum score threshold (0.0-1.0). Default is `0.3`.
    ///   - algorithm: The matching algorithm with its configuration. Default is `.editDistance()`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default configuration
    /// let defaultConfig = MatchConfig()
    ///
    /// // Smith-Waterman mode
    /// let swConfig = MatchConfig(algorithm: .smithWaterman())
    ///
    /// // Strict matching with custom ED config
    /// let strictConfig = MatchConfig(
    ///     minScore: 0.7,
    ///     algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))
    /// )
    /// ```
    public init(
        minScore: Double = 0.3,
        algorithm: MatchingAlgorithm = .editDistance()
    ) {
        self.minScore = minScore
        self.algorithm = algorithm
    }

    /// The edit distance configuration, if using edit distance mode.
    ///
    /// Returns `nil` when ``algorithm`` is ``MatchingAlgorithm/smithWaterman(_:)``.
    public var editDistanceConfig: EditDistanceConfig? {
        if case .editDistance(let config) = algorithm { return config }
        return nil
    }

    /// The Smith-Waterman configuration, if using Smith-Waterman mode.
    ///
    /// Returns `nil` when ``algorithm`` is ``MatchingAlgorithm/editDistance(_:)``.
    public var smithWatermanConfig: SmithWatermanConfig? {
        if case .smithWaterman(let config) = algorithm { return config }
        return nil
    }
}

// MARK: - CustomDebugStringConvertible

extension GapPenalty: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .none:
            "GapPenalty.none"
        case .linear(let perCharacter):
            "GapPenalty.linear(perCharacter: \(perCharacter))"
        case .affine(let open, let extend):
            "GapPenalty.affine(open: \(open), extend: \(extend))"
        }
    }
}

extension MatchingAlgorithm: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .editDistance(let config):
            "MatchingAlgorithm.editDistance(maxED: \(config.maxEditDistance), prefix: \(config.prefixWeight), gap: \(config.gapPenalty.debugDescription))"
        case .smithWaterman(let config):
            "MatchingAlgorithm.smithWaterman(match: \(config.scoreMatch), gapStart: \(config.penaltyGapStart), boundary: \(config.bonusBoundary))"
        }
    }
}

extension EditDistanceConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "EditDistanceConfig(maxED: \(maxEditDistance), longED: \(longQueryMaxEditDistance)@\(longQueryThreshold), prefix: \(prefixWeight), substring: \(substringWeight), boundary: \(wordBoundaryBonus), consecutive: \(consecutiveBonus), gap: \(gapPenalty.debugDescription), firstMatch: \(firstMatchBonus)@\(firstMatchBonusRange), length: \(lengthPenalty), acronym: \(acronymWeight))"
    }
}

extension MatchConfig: CustomDebugStringConvertible {
    public var debugDescription: String {
        "MatchConfig(minScore: \(minScore), algorithm: \(algorithm.debugDescription))"
    }
}
