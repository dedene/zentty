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

/// A prepared query optimized for repeated matching against multiple candidates.
///
/// `FuzzyQuery` contains precomputed data structures that accelerate fuzzy matching.
/// Create instances using ``FuzzyMatcher/prepare(_:)`` rather than the initializer directly.
///
/// ## Overview
///
/// Query preparation is a one-time cost that enables efficient matching against
/// many candidates. The prepared query includes:
///
/// - **Lowercased bytes**: UTF-8 representation for case-insensitive matching
/// - **Character bitmask**: Fast prefilter for character presence checking
/// - **Trigrams**: 3-character sequences for similarity estimation
///
/// ## Example
///
/// ```swift
/// let matcher = FuzzyMatcher()
///
/// // Prepare once
/// let query = matcher.prepare("getUser")
///
/// // Match against many candidates
/// var buffer = matcher.makeBuffer()
/// for candidate in thousandsOfCandidates {
///     if let match = matcher.score(candidate, against: query, buffer: &buffer) {
///         // Process match...
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// `FuzzyQuery` is immutable and `Sendable`, making it safe to share across threads.
/// Multiple threads can use the same prepared query simultaneously with their own
/// ``ScoringBuffer`` instances.
public struct FuzzyQuery: Sendable, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.original == rhs.original
            && lhs.lowercased == rhs.lowercased
            && lhs.charBitmask == rhs.charBitmask
            && lhs.trigrams == rhs.trigrams
            && lhs.containsSpaces == rhs.containsSpaces
            && lhs.config == rhs.config
            && lhs.effectiveMaxEditDistance == rhs.effectiveMaxEditDistance
            && lhs.bitmaskTolerance == rhs.bitmaskTolerance
            && lhs.minCandidateLength == rhs.minCandidateLength
            && lhs.maxSmithWatermanScore == rhs.maxSmithWatermanScore
            && lhs.atoms.count == rhs.atoms.count
            && zip(lhs.atoms, rhs.atoms).allSatisfy { $0.start == $1.start && $0.length == $1.length }
    }

    /// The original query string as provided to ``FuzzyMatcher/prepare(_:)``.
    ///
    /// This preserves the original casing for display purposes, while matching
    /// is performed case-insensitively using ``lowercased``.
    public let original: String

    /// The query converted to lowercased UTF-8 bytes.
    ///
    /// Used internally for case-insensitive edit distance computation.
    /// ASCII, Latin-1 Supplement, Greek, and Cyrillic letters are lowercased;
    /// other characters pass through unchanged.
    @usableFromInline let lowercased: [UInt8]

    /// Bitmask representing character presence in the query.
    ///
    /// A 64-bit bloom filter where:
    /// - Bits 0-25: Letters a-z
    /// - Bits 26-35: Digits 0-9
    /// - Bit 36: Underscore
    /// - Bits 37-63: 2-byte UTF-8 characters (Latin-1 Supplement, Greek, Cyrillic)
    ///
    /// Used for fast prefiltering: if a character in the query is absent from
    /// a candidate, that bit will be set in `queryMask & ~candidateMask`.
    @usableFromInline let charBitmask: UInt64

    /// Set of 3-byte trigram hashes for the query.
    @usableFromInline let trigrams: Set<UInt32>

    /// Whether the query contains space characters.
    @usableFromInline let containsSpaces: Bool

    /// The configuration used for matching with this query.
    public let config: MatchConfig

    /// Adaptive max edit distance, tightened for short queries.
    @usableFromInline let effectiveMaxEditDistance: Int

    /// Bitmask prefilter tolerance: 0 for short queries, effectiveMaxEditDistance otherwise.
    @usableFromInline let bitmaskTolerance: Int

    /// Minimum candidate length that can pass the length bounds prefilter.
    @usableFromInline let minCandidateLength: Int

    /// Maximum possible Smith-Waterman raw score for this query.
    @usableFromInline let maxSmithWatermanScore: Int

    /// Byte ranges of individual query words for multi-word Smith-Waterman matching.
    @usableFromInline let atoms: [(start: Int, length: Int)]

    /// Creates a new fuzzy query with precomputed matching data.
    @usableFromInline
    init(
        original: String,
        lowercased: [UInt8],
        charBitmask: UInt64,
        trigrams: Set<UInt32>,
        containsSpaces: Bool = false,
        config: MatchConfig
    ) {
        self.original = original
        self.lowercased = lowercased
        self.charBitmask = charBitmask
        self.trigrams = trigrams
        self.containsSpaces = containsSpaces
        self.config = config

        let queryLength = lowercased.count

        switch config.algorithm {
        case .editDistance(let edConfig):
            let maxED = queryLength >= edConfig.longQueryThreshold
                ? edConfig.longQueryMaxEditDistance
                : edConfig.maxEditDistance
            let emed = min(maxED, max(1, (queryLength - 1) / 2))
            self.effectiveMaxEditDistance = emed
            self.bitmaskTolerance = queryLength <= 3 ? 0 : emed
            self.minCandidateLength = queryLength - emed

        case .smithWaterman:
            self.effectiveMaxEditDistance = 0
            self.bitmaskTolerance = 0
            self.minCandidateLength = 0
        }

        // Split multi-word Smith-Waterman queries into atoms
        if case .smithWaterman(let swConfig) = config.algorithm,
            containsSpaces, swConfig.splitSpaces {
            var result: [(start: Int, length: Int)] = []
            var segStart = 0
            for i in 0..<queryLength {
                if lowercased[i] == 0x20 {
                    if i > segStart {
                        result.append((start: segStart, length: i - segStart))
                    }
                    segStart = i + 1
                }
            }
            if queryLength > segStart {
                result.append((start: segStart, length: queryLength - segStart))
            }
            self.atoms = result
        } else {
            self.atoms = []
        }

        if case .smithWaterman(let sw) = config.algorithm, queryLength > 0 {
            if atoms.count > 1 {
                var totalMax = 0
                for atom in atoms {
                    let atomLen = atom.length
                    totalMax += atomLen * sw.scoreMatch
                        + sw.bonusBoundaryWhitespace * (sw.bonusFirstCharMultiplier + atomLen - 1)
                }
                self.maxSmithWatermanScore = totalMax
            } else {
                self.maxSmithWatermanScore =
                    queryLength * sw.scoreMatch
                    + sw.bonusBoundaryWhitespace * (sw.bonusFirstCharMultiplier + queryLength - 1)
            }
        } else {
            self.maxSmithWatermanScore = 0
        }
    }
}
