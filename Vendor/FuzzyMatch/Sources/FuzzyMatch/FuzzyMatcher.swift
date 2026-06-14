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

/// A high-performance fuzzy string matching library.
///
/// `FuzzyMatcher` provides configurable fuzzy matching with two matching modes:
/// - **Edit distance** (default) — Penalty-driven scoring using Damerau-Levenshtein
///   with prefix, substring, subsequence, and acronym matching phases
/// - **Smith-Waterman** — Bonus-driven local alignment scoring (similar to nucleo/fzf)
///   with word boundary bonuses and multi-word atom splitting
///
/// Both modes share:
/// - Fast prefiltering using character bitmasks and trigrams
/// - Zero-allocation hot path when using prepared queries and buffers
/// - Highlight ranges for displaying matched characters in UI
/// - Convenience methods for quick one-shot scoring and top-N matching
///
/// ## Overview
///
/// FuzzyMatcher is designed for searching code identifiers, file names, and other
/// text where typo tolerance and fast performance are important. It offers two API levels:
///
/// **Convenience API** — for quick use, prototyping, or small candidate sets:
/// ```swift
/// let matcher = FuzzyMatcher()
/// if let match = matcher.score("getUserById", against: "getUser") {
///     print("Score: \(match.score)")
/// }
/// let top3 = matcher.topMatches(candidates, against: matcher.prepare("config"), limit: 3)
/// ```
///
/// **High-Performance API** — for production hot paths with zero heap allocations:
/// 1. Create a `FuzzyMatcher` with your desired configuration
/// 2. Prepare queries once for repeated use with ``prepare(_:)``
/// 3. Create a reusable buffer with ``makeBuffer()``
/// 4. Score candidates using ``score(_:against:buffer:)``
///
/// ## Matching Modes
///
/// ```swift
/// // Edit distance (default) — best for typo tolerance and prefix-aware search
/// let edMatcher = FuzzyMatcher()
///
/// // Smith-Waterman — best for multi-word queries and code/file search
/// let swMatcher = FuzzyMatcher(config: .smithWaterman)
/// ```
///
/// Both modes use the same API surface and produce scores normalized to 0.0–1.0.
/// See ``MatchingAlgorithm`` for details on each mode.
///
/// ## Topics
///
/// ### Creating a Matcher
/// - ``init(config:)``
/// - ``config``
///
/// ### Preparing Queries
/// - ``prepare(_:)``
/// - ``makeBuffer()``
///
/// ### High-Performance Scoring
/// - ``score(_:against:buffer:)``
///
/// ### Convenience Scoring
/// - ``score(_:against:)``
/// - ``topMatches(_:against:limit:)-(_,FuzzyQuery,_)``
/// - ``topMatches(_:against:limit:)-(_,String,_)``
/// - ``matches(_:against:)-(_,FuzzyQuery)``
/// - ``matches(_:against:)-(_,String)``
///
/// ### Highlighting
/// - ``highlight(_:against:)-(_,FuzzyQuery)``
/// - ``highlight(_:against:)-(_,String)``
///
/// ## Example
///
/// ```swift
/// // Create a matcher with default configuration
/// let matcher = FuzzyMatcher()
///
/// // Prepare a query for repeated use
/// let query = matcher.prepare("getUser")
///
/// // Create a reusable buffer (one per thread for concurrent use)
/// var buffer = matcher.makeBuffer()
///
/// // Score multiple candidates efficiently (zero allocations per call)
/// let candidates = ["getUserById", "getUsername", "setUser", "fetchData"]
/// for candidate in candidates {
///     if let match = matcher.score(candidate, against: query, buffer: &buffer) {
///         print("\(candidate): \(match.score)")
///     }
/// }
/// ```
public struct FuzzyMatcher: Sendable {
    /// The configuration controlling matching behavior.
    ///
    /// This configuration is applied to all queries prepared by this matcher.
    /// To use different configurations, create separate `FuzzyMatcher` instances.
    public let config: MatchConfig

    /// Creates a new fuzzy matcher with the specified configuration.
    ///
    /// - Parameter config: The configuration for matching behavior.
    ///   Defaults to ``MatchConfig/init(minScore:algorithm:)`` with standard values.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default configuration (edit distance, minScore: 0.3)
    /// let defaultMatcher = FuzzyMatcher()
    ///
    /// // Custom configuration for stricter matching
    /// let strictConfig = MatchConfig(
    ///     minScore: 0.7,
    ///     algorithm: .editDistance(EditDistanceConfig(maxEditDistance: 1))
    /// )
    /// let strictMatcher = FuzzyMatcher(config: strictConfig)
    /// ```
    public init(config: MatchConfig = .init()) {
        self.config = config
    }

    /// Prepares a query string for repeated matching against multiple candidates.
    ///
    /// Query preparation precomputes data structures that accelerate matching:
    /// - Lowercased UTF-8 byte representation
    /// - Character presence bitmask for fast prefiltering
    /// - Trigram set for similarity filtering
    ///
    /// For best performance, prepare each query once and reuse it for all candidates.
    ///
    /// - Parameter query: The query string to prepare.
    /// - Returns: A prepared ``FuzzyQuery`` optimized for matching.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    ///
    /// // Prepare the query once
    /// let query = matcher.prepare("config")
    ///
    /// // Use it to score many candidates
    /// var buffer = matcher.makeBuffer()
    /// for candidate in largeDataset {
    ///     if let match = matcher.score(candidate, against: query, buffer: &buffer) {
    ///         // Process match...
    ///     }
    /// }
    /// ```
    public func prepare(_ query: String) -> FuzzyQuery {
        // Convert to lowercased UTF-8 bytes (stripping combining diacritical marks)
        let utf8Bytes = Array(query.utf8)
        var lowercased = [UInt8](repeating: 0, count: utf8Bytes.count)
        let isASCII = utf8Bytes.allSatisfy { $0 < 0x80 }
        let lowercasedLength = utf8Bytes.withUnsafeBufferPointer { ptr in
            lowercaseUTF8(from: ptr, into: &lowercased, mapping: nil, isASCII: isASCII)
        }

        // Truncate to actual length (combining marks may have been stripped)
        if lowercasedLength < lowercased.count {
            lowercased.removeSubrange(lowercasedLength..<lowercased.count)
        }

        // Compute character bitmask
        let charBitmask = computeCharBitmask(lowercased)

        // Check if query contains spaces (multi-word)
        let containsSpaces = lowercased.contains(0x20)

        // Compute trigrams (only if query is long enough)
        let trigrams: Set<UInt32>
        if lowercased.count >= 3 {
            trigrams = computeTrigrams(lowercased)
        } else {
            trigrams = []
        }

        return FuzzyQuery(
            original: query,
            lowercased: lowercased,
            charBitmask: charBitmask,
            trigrams: trigrams,
            containsSpaces: containsSpaces,
            config: config
        )
    }

    /// Creates a new scoring buffer for use with the ``score(_:against:buffer:)`` method.
    ///
    /// Scoring buffers hold pre-allocated memory for the scoring computation,
    /// eliminating heap allocations in the hot path. For concurrent usage, create
    /// one buffer per thread.
    ///
    /// - Returns: A new ``ScoringBuffer`` instance.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("data")
    ///
    /// // Single-threaded usage
    /// var buffer = matcher.makeBuffer()
    /// for candidate in candidates {
    ///     matcher.score(candidate, against: query, buffer: &buffer)
    /// }
    ///
    /// // Concurrent usage - one buffer per task
    /// await withTaskGroup(of: Void.self) { group in
    ///     for chunk in chunks {
    ///         group.addTask {
    ///             var taskBuffer = matcher.makeBuffer()
    ///             // Use taskBuffer for this task's work...
    ///         }
    ///     }
    /// }
    /// ```
    public func makeBuffer() -> ScoringBuffer {
        ScoringBuffer()
    }

    /// Scores a candidate string against a prepared query.
    ///
    /// This is the primary hot-path method optimized for performance:
    /// - Uses prefilters to quickly reject non-matching candidates
    /// - Computes scoring (edit distance or Smith-Waterman DP) only for promising candidates
    /// - Performs zero heap allocations when using the provided buffer
    ///
    /// The method returns `nil` if:
    /// - The candidate fails prefiltering (too different from query)
    /// - The scoring distance exceeds the configured maximum (edit distance mode)
    /// - The computed score is below ``MatchConfig/minScore``
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to match against the query.
    ///   - query: A prepared query from ``prepare(_:)``.
    ///   - buffer: A reusable scoring buffer from ``makeBuffer()``.
    ///     Pass by reference (`inout`) for buffer reuse.
    /// - Returns: A ``ScoredMatch`` if the candidate matches, or `nil` if it doesn't
    ///   meet the matching criteria.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("usr")
    /// var buffer = matcher.makeBuffer()
    ///
    /// // Score individual candidates
    /// if let match = matcher.score("user", against: query, buffer: &buffer) {
    ///     print("Score: \(match.score), Kind: \(match.kind)")
    ///     // Output: Score: 0.75, Kind: prefix
    /// }
    ///
    /// // Filter and sort a list
    /// let results = candidates.compactMap { candidate -> (String, Float)? in
    ///     guard let match = matcher.score(candidate, against: query, buffer: &buffer) else {
    ///         return nil
    ///     }
    ///     return (candidate, match.score)
    /// }.sorted { $0.1 > $1.1 }
    /// ```
    ///
    /// ## Performance Notes
    ///
    /// - Reuse the same buffer across multiple `score` calls for zero allocations
    /// - The buffer automatically expands if needed for longer strings
    /// - For concurrent usage, each thread must have its own buffer
    @inline(__always)
    public func score(
        _ candidate: String,
        against query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> ScoredMatch? {
        // Record usage for shrink policy
        buffer.recordUsage(
            queryLength: query.lowercased.count,
            candidateLength: candidate.utf8.count
        )
        // String.withUTF8 borrows contiguous storage for native strings.
        // For maximum throughput, use score(utf8:against:buffer:) instead.
        var candidate = candidate
        return candidate.withUTF8 { candidateUTF8 in
            self.scoreDispatch(candidateUTF8, against: query, buffer: &buffer)
        }
    }

    /// Scores pre-extracted UTF-8 bytes against a prepared query.
    ///
    /// This `@inlinable` method accepts an `UnsafeBufferPointer<UInt8>` directly,
    /// letting the optimizer inline through the entire scoring path across module
    /// boundaries. On Swift 6.0, `String.withUTF8` is non-inlinable, which prevents
    /// cross-module optimization for the ``score(_:against:buffer:)`` overload. By
    /// calling `withUTF8` yourself and passing the buffer here, you recover full
    /// inlining — typically ~60% higher throughput than the String overload.
    ///
    /// When the library adopts Swift 6.2+ Span, the String API will recover full
    /// throughput via zero-cost contiguous access without closure overhead. At that
    /// point this method may be deprecated.
    ///
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("getUser")
    /// var buffer = matcher.makeBuffer()
    /// var candidate = "getUserById"
    /// candidate.withUTF8 { utf8 in
    ///     if let match = matcher.score(utf8: utf8, against: query, buffer: &buffer) {
    ///         print(match.score)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - candidateUTF8: A buffer pointer to the candidate's UTF-8 bytes.
    ///   - query: A prepared query from ``prepare(_:)``.
    ///   - buffer: A reusable scoring buffer from ``makeBuffer()``.
    /// - Returns: A ``ScoredMatch`` if the candidate matches, or `nil`.
    @inlinable
    public func score(
        utf8 candidateUTF8: UnsafeBufferPointer<UInt8>,
        against query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> ScoredMatch? {
        buffer.recordUsage(
            queryLength: query.lowercased.count,
            candidateLength: candidateUTF8.count
        )
        return scoreDispatch(candidateUTF8, against: query, buffer: &buffer)
    }

    /// Dispatches scoring to the appropriate algorithm implementation.
    @inline(__always)
    @inlinable
    internal func scoreDispatch(
        _ candidateUTF8: UnsafeBufferPointer<UInt8>,
        against query: FuzzyQuery,
        buffer: inout ScoringBuffer
    ) -> ScoredMatch? {
        switch query.config.algorithm {
        case .smithWaterman(let swConfig):
            return buffer.withSmithWatermanBuffers { candidateStorage, smithWatermanState, wordInitials in
                scoreSmithWatermanImpl(
                    candidateUTF8,
                    against: query,
                    swConfig: swConfig,
                    candidateStorage: &candidateStorage,
                    smithWatermanState: &smithWatermanState,
                    wordInitials: &wordInitials
                )
            }

        case .editDistance(let edConfig):
            // Fast path for 1-character queries: single scan, no buffer needed.
            // Skip for multi-byte queries (e.g. Latin Extended "à" = 2 UTF-8 bytes).
            let queryLength = query.lowercased.count
            if queryLength == 1 {
                return scoreTinyQuery1(
                    candidateUTF8,
                    candidateLength: candidateUTF8.count,
                    q0: query.lowercased[0],
                    edConfig: edConfig,
                    minScore: query.config.minScore
                )
            }
            return buffer.withEditDistanceBuffers { candidateStorage, editDistanceState, matchPositions, alignmentState, wordInitials in
                scoreImpl(
                    candidateUTF8,
                    against: query,
                    edConfig: edConfig,
                    candidateStorage: &candidateStorage,
                    editDistanceState: &editDistanceState,
                    matchPositions: &matchPositions,
                    alignmentState: &alignmentState,
                    wordInitials: &wordInitials
                )
            }
        }
    }

    // MARK: - Scoring State

    /// Shared mutable state passed between scoring phases.
    @usableFromInline
    internal struct ScoringState {
        @usableFromInline var bestScore: Double = -1.0
        @usableFromInline var bestKind: MatchKind = .prefix
        @usableFromInline var cachedPositionCount: Int = -1
        @usableFromInline var cachedBonus: Double = 0.0
        @usableFromInline var needsAlignment: Bool = false
        @usableFromInline var boundaryMask: UInt64 = 0
        @usableFromInline var effectiveMaxEditDistance: Int = 0

        @usableFromInline
        init() {}
    }

    // MARK: - scoreImpl Orchestrator

    /// Internal scoring implementation using UnsafeBufferPointer for efficient byte access.
    ///
    /// Takes buffer components as separate parameters to avoid exclusivity conflicts.
    @inlinable
    internal func scoreImpl(
        _ candidateUTF8: UnsafeBufferPointer<UInt8>,
        against query: FuzzyQuery,
        edConfig: EditDistanceConfig,
        candidateStorage: inout CandidateStorage,
        editDistanceState: inout EditDistanceState,
        matchPositions: inout [Int],
        alignmentState: inout AlignmentState,
        wordInitials: inout [UInt8]
    ) -> ScoredMatch? {
        let candidateLength = candidateUTF8.count
        let queryLength = query.lowercased.count

        // Handle empty cases
        if queryLength == 0 {
            return ScoredMatch(score: 1.0, kind: .exact)
        }
        if candidateLength == 0 {
            return nil
        }

        // Prefilter 1: Length bounds (uses precomputed minCandidateLength)
        if candidateLength < query.minCandidateLength {
            return nil
        }

        // Prefilter 2: Character bitmask — check BEFORE lowercasing to reject early
        // Combined bitmask + ASCII detection in a single O(n) pass (eliminates separate ASCII scan)
        let (candidateMask, candidateIsASCII) = computeCharBitmaskWithASCIICheck(candidateUTF8)
        if !passesCharBitmask(
            queryMask: query.charBitmask,
            candidateMask: candidateMask,
            maxEditDistance: query.bitmaskTolerance
        ) {
            return nil
        }

        let effectiveMaxEditDistance = query.effectiveMaxEditDistance

        // Ensure buffer capacity and lowercase the candidate
        editDistanceState.ensureCapacity(queryLength)
        candidateStorage.ensureCapacity(candidateLength)
        if matchPositions.count < queryLength {
            matchPositions = [Int](repeating: 0, count: queryLength)
        }

        let actualCandidateLength = lowercaseUTF8(
            from: candidateUTF8, into: &candidateStorage.bytes,
            mapping: nil, isASCII: candidateIsASCII
        )

        // Phase 2: Exact match (early exit — before buffer pointers, uses Array subscript)
        if let exact = checkExactMatch(
            candidateBytes: candidateStorage.bytes,
            query: query,
            candidateLength: actualCandidateLength
        ) {
            return exact
        }

        return candidateStorage.bytes.withUnsafeBufferPointer { bytesPtr in
            let candidateSpan = UnsafeBufferPointer(rebasing: bytesPtr[0..<actualCandidateLength])
            return query.lowercased.withUnsafeBufferPointer { querySpan -> ScoredMatch? in
                // Prefilter 3: Trigrams (only if query has enough trigrams to be selective)
                // Skip when threshold (queryTrigrams.count - 3*maxED) is non-positive,
                // since the filter would accept every candidate anyway.
                // Space-containing trigrams are excluded at computation time, so this
                // is safe for multi-word queries (see computeTrigrams for rationale).
                if query.lowercased.count >= 4
                    && query.trigrams.count > 3 * effectiveMaxEditDistance {
                    if !passesTrigramFilter(
                        candidateBytes: candidateSpan,
                        queryTrigrams: query.trigrams,
                        maxEditDistance: effectiveMaxEditDistance
                    ) {
                        return nil
                    }
                }

                // Compute word boundary mask for bonus calculation
                // Use the ORIGINAL (non-lowercased) bytes to detect camelCase transitions,
                // but assign bits at compressed (post-lowercasing) positions so they align
                // with candidateSpan indices used downstream.
                let boundaryMask = computeBoundaryMaskCompressed(originalBytes: candidateUTF8, isASCII: candidateIsASCII)

                let needsAlignment = edConfig.wordBoundaryBonus > 0
                    || edConfig.consecutiveBonus > 0
                    || edConfig.gapPenalty != .none
                    || edConfig.firstMatchBonus > 0

                var state = ScoringState()
                state.boundaryMask = boundaryMask
                state.effectiveMaxEditDistance = effectiveMaxEditDistance
                state.needsAlignment = needsAlignment

                // Phase 3: Prefix scoring
                let prefixDistance = scorePrefix(
                    querySpan: querySpan,
                    candidateSpan: candidateSpan,
                    query: query,
                    edConfig: edConfig,
                    candidateLength: actualCandidateLength,
                    state: &state,
                    editDistanceState: &editDistanceState,
                    matchPositions: &matchPositions,
                    alignmentState: &alignmentState
                )

                // Phase 4: Substring scoring
                scoreSubstring(
                    querySpan: querySpan,
                    candidateSpan: candidateSpan,
                    query: query,
                    edConfig: edConfig,
                    candidateLength: actualCandidateLength,
                    prefixDistance: prefixDistance,
                    state: &state,
                    editDistanceState: &editDistanceState,
                    matchPositions: &matchPositions,
                    alignmentState: &alignmentState
                )

                // Phase 5: Subsequence scoring
                scoreSubsequence(
                    querySpan: querySpan,
                    candidateSpan: candidateSpan,
                    query: query,
                    edConfig: edConfig,
                    candidateLength: actualCandidateLength,
                    state: &state,
                    matchPositions: &matchPositions,
                    alignmentState: &alignmentState
                )

                // Phase 6: Acronym scoring
                scoreAcronym(
                    querySpan: querySpan,
                    candidateSpan: candidateSpan,
                    candidateUTF8: candidateUTF8,
                    query: query,
                    candidateLength: actualCandidateLength,
                    acronymWeight: edConfig.acronymWeight,
                    state: &state,
                    wordInitials: &wordInitials
                )

                if state.bestScore >= query.config.minScore {
                    return ScoredMatch(score: min(state.bestScore, 1.0), kind: state.bestKind)
                }

                return nil
            }
        }
    }

    // MARK: - Phase Methods

    /// Phase 2: Check for exact match (case-insensitive).
    @inlinable
    internal func checkExactMatch(
        candidateBytes: [UInt8],
        query: FuzzyQuery,
        candidateLength: Int
    ) -> ScoredMatch? {
        let queryLength = query.lowercased.count
        guard candidateLength == queryLength else { return nil }
        for i in 0..<queryLength {
            if candidateBytes[i] != query.lowercased[i] {
                return nil
            }
        }
        return ScoredMatch(score: 1.0, kind: .exact)
    }

    /// Phase 3: Prefix edit distance scoring.
    /// Returns the prefix distance (nil if prefix ED exceeded threshold).
    @inlinable
    internal func scorePrefix(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        query: FuzzyQuery,
        edConfig: EditDistanceConfig,
        candidateLength: Int,
        state: inout ScoringState,
        editDistanceState: inout EditDistanceState,
        matchPositions: inout [Int],
        alignmentState: inout AlignmentState
    ) -> Int? {
        let queryLength = query.lowercased.count

        let prefixDistance = prefixEditDistance(
            query: querySpan,
            candidate: candidateSpan,
            state: &editDistanceState,
            maxEditDistance: state.effectiveMaxEditDistance
        )

        guard let distance = prefixDistance else { return nil }

        // Short query same-length restriction: for queries <= 3 chars, only allow
        // prefix ED typos against same-length candidates. Prevents "UDS" from
        // matching "USD Fund" while allowing "UDS" -> "USD" (both 3 chars).
        // Reduces match counts on large corpora. Distance=0 matches are unaffected.
        if queryLength <= 3 && distance > 0 && candidateLength != queryLength {
            return nil
        }

        var score = normalizedScore(
            editDistance: distance,
            queryLength: queryLength,
            kind: .prefix,
            config: edConfig
        )

        // Same-length near-exact boost: when candidateLength == queryLength,
        // the prefix match covers the entire candidate — essentially a typo
        // correction (e.g., "UDS" → "USD"). Recover 70% of the gap to 1.0
        // so these rank well above subsequence matches against long strings.
        if candidateLength == queryLength && distance > 0 {
            score += (1.0 - score) * 0.7
        }

        // Calculate bonuses using DP-optimal alignment
        if state.needsAlignment {
            let (positionCount, bonus) = computeAlignmentIfNeeded(
                querySpan: querySpan,
                candidateSpan: candidateSpan,
                query: query,
                edConfig: edConfig,
                state: &state,
                matchPositions: &matchPositions,
                alignmentState: &alignmentState
            )
            if positionCount > 0 {
                // Cap bonuses: only exact (distance=0) can reach 1.0.
                // Non-exact matches can recover at most 80% of the gap to 1.0.
                if distance > 0 {
                    let maxBonus = (1.0 - score) * 0.8
                    score += min(bonus, maxBonus)
                } else {
                    score = min(score + bonus, 1.0)
                }
            }
        }

        // Length penalty: prefer shorter/tighter candidates over long ones
        if candidateLength > queryLength {
            let lengthPenalty = Double(candidateLength - queryLength) * edConfig.lengthPenalty
            score -= lengthPenalty
            // Exact prefix recovery: offset most of the length penalty when
            // the query matches the beginning of the candidate exactly.
            if distance == 0 {
                score += min(lengthPenalty * 0.9, 0.15)
            }
        }

        score = min(score, 1.0)

        if score >= query.config.minScore {
            state.bestScore = score
            state.bestKind = .prefix
        }

        return distance
    }

    /// Phase 4: Substring edit distance scoring.
    @inlinable
    internal func scoreSubstring(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        query: FuzzyQuery,
        edConfig: EditDistanceConfig,
        candidateLength: Int,
        prefixDistance: Int?,
        state: inout ScoringState,
        editDistanceState: inout EditDistanceState,
        matchPositions: inout [Int],
        alignmentState: inout AlignmentState
    ) {
        let queryLength = query.lowercased.count

        // Skip when prefix match is strong or prefix distance is 0
        // (prefix score with recovery 0.9 always beats substring with 0.8)
        guard state.bestScore < 0.7 && prefixDistance != 0 else { return }

        let substringDist = substringEditDistance(
            query: querySpan,
            candidate: candidateSpan,
            state: &editDistanceState,
            maxEditDistance: state.effectiveMaxEditDistance
        )

        guard let distance = substringDist else { return }

        // Short query same-length restriction (see scorePrefix for rationale).
        if queryLength <= 3 && distance > 0 && candidateLength != queryLength {
            return
        }

        var score = normalizedScore(
            editDistance: distance,
            queryLength: queryLength,
            kind: .substring,
            config: edConfig
        )

        // Calculate bonuses using cached or fresh DP-optimal alignment
        if state.needsAlignment {
            if state.cachedPositionCount < 0 {
                // For short queries with exact substring, try contiguous recovery
                if queryLength <= 4 {
                    let positionCount = findMatchPositions(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: state.boundaryMask,
                        positions: &matchPositions
                    )

                    // If exact substring exists but greedy found scattered positions,
                    // scan for a contiguous occurrence (better bonuses + whole-word recovery)
                    if distance == 0 && positionCount == queryLength {
                        let firstPos = matchPositions[0]
                        let lastPos = matchPositions[positionCount - 1]
                        if lastPos - firstPos + 1 != queryLength {
                            let contiguousStart = findContiguousSubstring(
                                query: querySpan,
                                candidate: candidateSpan,
                                boundaryMask: state.boundaryMask
                            )
                            if contiguousStart >= 0 {
                                for i in 0..<queryLength {
                                    matchPositions[i] = contiguousStart + i
                                }
                            }
                        }
                    }

                    state.cachedPositionCount = positionCount
                    state.cachedBonus = positionCount > 0 ? calculateBonuses(
                        matchPositions: matchPositions,
                        positionCount: positionCount,
                        candidateBytes: candidateSpan,
                        boundaryMask: state.boundaryMask,
                        config: edConfig
                    ) : 0.0
                } else {
                    let (positionCount, bonus) = optimalAlignment(
                        query: querySpan,
                        candidate: candidateSpan,
                        boundaryMask: state.boundaryMask,
                        positions: &matchPositions,
                        state: &alignmentState,
                        config: edConfig
                    )
                    state.cachedPositionCount = positionCount
                    state.cachedBonus = bonus
                }
            }
            if state.cachedPositionCount > 0 {
                // Cap bonuses for non-exact substring matches
                if distance > 0 {
                    let maxBonus = (1.0 - score) * 0.8
                    score += min(state.cachedBonus, maxBonus)
                } else {
                    score = min(score + state.cachedBonus, 1.0)
                }
            }
        }

        // Length penalty for substring matches
        if candidateLength > queryLength {
            let lengthPenalty = Double(candidateLength - queryLength) * edConfig.lengthPenalty
            score -= lengthPenalty

            // Whole-word substring recovery
            if distance == 0 && state.cachedPositionCount == queryLength {
                let firstPos = matchPositions[0]
                let lastPos = matchPositions[state.cachedPositionCount - 1]
                if lastPos - firstPos + 1 == queryLength {
                    let startBound = isWordBoundary(at: firstPos, in: candidateSpan)
                    let nextPos = lastPos + 1
                    let endBound: Bool
                    if nextPos >= candidateLength {
                        endBound = true
                    } else {
                        let nextByte = candidateSpan[nextPos]
                        let isAlphaNum = (nextByte >= 0x30 && nextByte <= 0x39)
                            || (nextByte >= 0x41 && nextByte <= 0x5A)
                            || (nextByte >= 0x61 && nextByte <= 0x7A)
                        endBound = !isAlphaNum
                    }
                    if startBound && endBound {
                        score += min(lengthPenalty * 0.8, 0.15)
                    }
                }
            }
        }

        score = min(score, 1.0)

        if score > state.bestScore && score >= query.config.minScore {
            state.bestScore = score
            state.bestKind = .substring
        }
    }

    /// Phase 5: Subsequence (gap-based) scoring fallback.
    @inlinable
    internal func scoreSubsequence(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        query: FuzzyQuery,
        edConfig: EditDistanceConfig,
        candidateLength: Int,
        state: inout ScoringState,
        matchPositions: inout [Int],
        alignmentState: inout AlignmentState
    ) {
        let queryLength = query.lowercased.count

        // Only try if edit distance matching didn't find a good match
        guard state.bestScore < query.config.minScore else { return }

        // Quick O(n+m) subsequence check before expensive O(n×m) alignment.
        // When alignment isn't cached, verify all query chars exist in order
        // in the candidate. Many candidates that failed ED won't be subsequences.
        if state.cachedPositionCount < 0 {
            var qi = 0
            for ci in 0..<candidateSpan.count {
                if candidateSpan[ci] == querySpan[qi] {
                    qi &+= 1
                    if qi == queryLength { break }
                }
            }
            if qi < queryLength { return }
        }

        // Use cached or fresh DP-optimal alignment
        let (positionCount, bonus) = computeAlignmentIfNeeded(
            querySpan: querySpan,
            candidateSpan: candidateSpan,
            query: query,
            edConfig: edConfig,
            state: &state,
            matchPositions: &matchPositions,
            alignmentState: &alignmentState
        )

        // If we found all query characters in order, compute a subsequence score
        guard positionCount == queryLength else { return }

        // Base score for subsequence: ratio of query length to total gaps
        var totalGaps = 0
        for i in 1..<positionCount {
            totalGaps += matchPositions[i] - matchPositions[i - 1] - 1
        }
        totalGaps += matchPositions[0]

        let gapRatio = Double(totalGaps) / Double(candidateLength)
        var score = max(0.3, 1.0 - gapRatio)

        // Apply match type weight
        score *= edConfig.substringWeight

        // Apply the DP-computed bonus
        // Cap bonuses at 80% recovery (consistent with prefix/substring paths).
        let maxBonus = (1.0 - score) * 0.8
        score += min(bonus, maxBonus)

        // Length penalty for subsequence matches
        if candidateLength > queryLength {
            let lengthPenalty = Double(candidateLength - queryLength) * edConfig.lengthPenalty
            score -= lengthPenalty
        }

        score = min(score, 1.0)

        if score > state.bestScore && score >= query.config.minScore {
            state.bestScore = score
            state.bestKind = .substring
        }
    }

    /// Phase 6: Acronym (word-initial) matching.
    @inlinable
    internal func scoreAcronym(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        candidateUTF8: UnsafeBufferPointer<UInt8>,
        query: FuzzyQuery,
        candidateLength: Int,
        acronymWeight: Double,
        state: inout ScoringState,
        wordInitials: inout [UInt8]
    ) {
        let queryLength = query.lowercased.count

        // Runs for short queries (2-8 chars) and competes with other match types
        guard queryLength >= 2 && queryLength <= 8 else { return }

        // Quick word count check using boundary mask (covers first 64 chars)
        // For long candidates, scan beyond byte 64 for additional word boundaries
        var wordCount = state.boundaryMask.nonzeroBitCount
        if candidateLength > 64 {
            for i in 64..<candidateLength {
                if isWordBoundary(at: i, in: candidateSpan) {
                    wordCount += 1
                }
            }
        }
        guard wordCount >= 3 && wordCount >= queryLength else { return }

        // Extract word-initial characters from the lowercased candidate
        var initialCount = 0
        let limit = min(candidateLength, 64)
        for i in 0..<limit {
            if (state.boundaryMask & (1 << i)) != 0 {
                if initialCount >= wordInitials.count {
                    wordInitials.append(contentsOf: repeatElement(UInt8(0), count: wordInitials.count))
                }
                wordInitials[initialCount] = candidateSpan[i]
                initialCount += 1
            }
        }
        if candidateLength > 64 {
            for i in 64..<candidateLength {
                // Use compressed candidateSpan for boundary check (consistent with mask)
                // Note: camelCase detection is lost on lowercased bytes, but this is an
                // existing limitation — boundaries from underscores, digits, non-alnum
                // are still detected correctly.
                if isWordBoundary(at: i, in: candidateSpan) {
                    if initialCount >= wordInitials.count {
                        wordInitials.append(contentsOf: repeatElement(UInt8(0), count: wordInitials.count))
                    }
                    wordInitials[initialCount] = candidateSpan[i]
                    initialCount += 1
                }
            }
        }

        // Subsequence check: is query a subsequence of wordInitials[0..<initialCount]?
        var qi = 0
        for wi in 0..<initialCount {
            if qi < queryLength && querySpan[qi] == wordInitials[wi] {
                qi += 1
            }
        }
        guard qi == queryLength else { return }

        let coverage = Double(queryLength) / Double(initialCount)
        let score = min((0.55 + 0.4 * coverage) * acronymWeight, 1.0)
        if score > state.bestScore && score >= query.config.minScore {
            state.bestScore = score
            state.bestKind = .acronym
        }
    }

    // MARK: - Alignment Cache Helper

    /// Computes alignment if not already cached, updating state. Returns (positionCount, bonus).
    @inlinable
    internal func computeAlignmentIfNeeded(
        querySpan: UnsafeBufferPointer<UInt8>,
        candidateSpan: UnsafeBufferPointer<UInt8>,
        query: FuzzyQuery,
        edConfig: EditDistanceConfig,
        state: inout ScoringState,
        matchPositions: inout [Int],
        alignmentState: inout AlignmentState
    ) -> (positionCount: Int, bonus: Double) {
        if state.cachedPositionCount >= 0 {
            return (state.cachedPositionCount, state.cachedBonus)
        }

        let queryLength = query.lowercased.count
        let positionCount: Int
        let bonus: Double

        if queryLength <= 4 {
            positionCount = findMatchPositions(
                query: querySpan,
                candidate: candidateSpan,
                boundaryMask: state.boundaryMask,
                positions: &matchPositions
            )
            bonus = positionCount > 0 ? calculateBonuses(
                matchPositions: matchPositions,
                positionCount: positionCount,
                candidateBytes: candidateSpan,
                boundaryMask: state.boundaryMask,
                config: edConfig
            ) : 0.0
        } else {
            (positionCount, bonus) = optimalAlignment(
                query: querySpan,
                candidate: candidateSpan,
                boundaryMask: state.boundaryMask,
                positions: &matchPositions,
                state: &alignmentState,
                config: edConfig
            )
        }

        state.cachedPositionCount = positionCount
        state.cachedBonus = bonus
        return (positionCount, bonus)
    }

    /// Single-character query fast path.
    @inlinable
    internal func scoreTinyQuery1(
        _ candidateUTF8: UnsafeBufferPointer<UInt8>,
        candidateLength: Int,
        q0: UInt8,
        edConfig: EditDistanceConfig,
        minScore: Double
    ) -> ScoredMatch? {
        // Exact match: 1-byte candidate matches query
        if candidateLength == 1 {
            if lowercaseASCII(candidateUTF8[0]) == q0 {
                return ScoredMatch(score: 1.0, kind: .exact)
            }
            return nil
        }

        // Exact match: 2-byte Latin-1 candidate normalizes to same ASCII letter
        if candidateLength == 2 && candidateUTF8[0] == 0xC3 {
            let lowered = lowercaseLatinExtended(candidateUTF8[1])
            if latin1ToASCII(lowered) == q0 {
                return ScoredMatch(score: 1.0, kind: .exact)
            }
        }

        // Scan for best match position
        var bestPos = -1
        var bestIsBoundary = false
        var i = 0
        while i < candidateLength {
            let byte = candidateUTF8[i]
            // Check Latin-1 diacritics that normalize to ASCII
            if byte == 0xC3 && i + 1 < candidateLength {
                let lowered = lowercaseLatinExtended(candidateUTF8[i + 1])
                let ascii = latin1ToASCII(lowered)
                if ascii == q0 {
                    // Diacritic normalizes to query char — treat as match at position i
                    if i == 0 {
                        var score = 1.0
                        let bonus = edConfig.wordBoundaryBonus + edConfig.firstMatchBonus
                        score = min(score + bonus, 1.0)
                        let lengthPenalty = Double(candidateLength - 1) * edConfig.lengthPenalty
                        score -= lengthPenalty
                        score += min(lengthPenalty * 0.9, 0.15)
                        score = min(score, 1.0)
                        if score >= minScore {
                            return ScoredMatch(score: score, kind: .prefix)
                        }
                        return nil
                    }
                    let isBound = isWordBoundaryInline(at: i, prev: candidateUTF8[i - 1], curr: byte)
                    if bestPos == -1 || (!bestIsBoundary && isBound) {
                        bestPos = i
                        bestIsBoundary = isBound
                        if isBound { break }
                    }
                }
                i += 2
                continue
            }
            // Skip other 2-byte sequences (Greek, Cyrillic)
            if isMultiByteLead(byte) {
                i += 2
                continue
            }
            let lower = lowercaseASCII(byte)
            if lower == q0 {
                // Position 0 prefix: early exit with best possible score
                if i == 0 {
                    var score = 1.0 // normalizedScore(ed:0, qLen:1, .prefix) = 1.0
                    // Bonus: boundary(pos 0) + firstMatchBonus(full decay at pos 0)
                    let bonus = edConfig.wordBoundaryBonus + edConfig.firstMatchBonus
                    score = min(score + bonus, 1.0)
                    // Length penalty with prefix recovery
                    let lengthPenalty = Double(candidateLength - 1) * edConfig.lengthPenalty
                    score -= lengthPenalty
                    score += min(lengthPenalty * 0.9, 0.15)
                    score = min(score, 1.0)
                    if score >= minScore {
                        return ScoredMatch(score: score, kind: .prefix)
                    }
                    return nil
                }
                let isBound = isWordBoundaryInline(at: i, prev: candidateUTF8[i - 1], curr: byte)
                if bestPos == -1 || (!bestIsBoundary && isBound) {
                    bestPos = i
                    bestIsBoundary = isBound
                    if isBound { break } // boundary is best we can get
                }
            }
            i += 1
        }

        if bestPos == -1 { return nil }

        // Substring match with distance 0
        var score = 1.0 // normalizedScore(ed:0, qLen:1, .substring) = 1.0
        // Bonuses
        var bonus = 0.0
        if bestIsBoundary { bonus += edConfig.wordBoundaryBonus }
        if edConfig.firstMatchBonus > 0 && bestPos < edConfig.firstMatchBonusRange {
            let decay = 1.0 - (Double(bestPos) / Double(edConfig.firstMatchBonusRange))
            bonus += edConfig.firstMatchBonus * decay
        }
        score = min(score + bonus, 1.0)
        // Length penalty
        if candidateLength > 1 {
            let lengthPenalty = Double(candidateLength - 1) * edConfig.lengthPenalty
            score -= lengthPenalty
            // Whole-word substring recovery: boundary on both sides
            if bestIsBoundary {
                let nextPos = bestPos + 1
                let endBound: Bool
                if nextPos >= candidateLength {
                    endBound = true
                } else {
                    let nextByte = candidateUTF8[nextPos]
                    let isAlphaNum = (nextByte >= 0x30 && nextByte <= 0x39)
                        || (nextByte >= 0x41 && nextByte <= 0x5A)
                        || (nextByte >= 0x61 && nextByte <= 0x7A)
                    endBound = !isAlphaNum
                }
                if endBound {
                    score += min(lengthPenalty * 0.8, 0.15)
                }
            }
        }
        score = min(score, 1.0)

        if score >= minScore {
            return ScoredMatch(score: score, kind: .substring)
        }
        return nil
    }

    /// Inline word boundary check using previous and current bytes.
    @inlinable
    internal func isWordBoundaryInline(at index: Int, prev: UInt8, curr: UInt8) -> Bool {
        if index == 0 { return true }
        // After underscore
        if prev == 0x5F { return true }
        // After digit
        if prev >= 0x30 && prev <= 0x39 { return true }
        // Lowercase to uppercase (camelCase)
        let prevIsLower = prev >= 0x61 && prev <= 0x7A
        let currIsUpper = curr >= 0x41 && curr <= 0x5A
        if prevIsLower && currIsUpper { return true }
        // After non-alphanumeric
        let prevIsAlnum = (prev >= 0x30 && prev <= 0x39)
            || (prev >= 0x41 && prev <= 0x5A)
            || (prev >= 0x61 && prev <= 0x7A)
            || prev == 0xC3                        // Latin-1 lead
            || prev == 0xCE || prev == 0xCF        // Greek lead
            || prev == 0xD0 || prev == 0xD1        // Cyrillic lead
            || (prev >= 0x80 && prev <= 0xBF)      // continuation byte
        if !prevIsAlnum { return true }
        return false
    }
}
