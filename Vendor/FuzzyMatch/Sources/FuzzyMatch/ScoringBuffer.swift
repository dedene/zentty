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

/// Storage for lowercased candidate bytes and precomputed per-position bonus values.
///
/// Separated into its own struct to allow buffer borrowing without conflicting
/// with mutation of other scoring state.
@usableFromInline
internal struct CandidateStorage: Sendable {
    /// Reusable buffer for lowercased candidate bytes.
    @usableFromInline var bytes: [UInt8]

    /// Precomputed per-position bonus values for Smith-Waterman scoring.
    @usableFromInline var bonus: [Int32]

    /// Creates candidate storage with the specified initial capacity.
    @usableFromInline
    init(maxLength: Int = 128) {
        self.bytes = [UInt8](repeating: 0, count: maxLength)
        self.bonus = [Int32](repeating: 0, count: maxLength)
    }

    /// Ensures the buffer has sufficient capacity.
    @inlinable
    mutating func ensureCapacity(_ length: Int) {
        if bytes.count < length {
            bytes = [UInt8](repeating: 0, count: length)
            bonus = [Int32](repeating: 0, count: length)
        }
    }

    /// Provides immutable buffer pointer access to both `bytes` and `bonus` simultaneously.
    ///
    /// Non-mutating read-only counterpart to ``withMutableBuffers``.
    /// Must be a method on `self` so Swift sees disjoint access to stored properties
    /// (calling `bytes.withUnsafeBufferPointer` then `bonus.withUnsafeBufferPointer`
    /// from outside would trigger an overlapping-access error on the struct).
    @inlinable
    func withReadBuffers<R>(
        length: Int,
        _ body: (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<Int32>) -> R
    ) -> R {
        bytes.withUnsafeBufferPointer { bytesPtr in
            bonus.withUnsafeBufferPointer { bonusPtr in
                body(
                    UnsafeBufferPointer(rebasing: bytesPtr[0..<length]),
                    UnsafeBufferPointer(rebasing: bonusPtr[0..<length])
                )
            }
        }
    }

    /// Provides mutable raw pointer access to both `bytes` and `bonus` simultaneously.
    ///
    /// Eliminates `Array.subscript.modify` coroutine overhead in hot loops where
    /// bounds checking has already been guaranteed by `ensureCapacity`.
    /// Must be a method on `self` so Swift sees disjoint access to stored properties
    /// (calling `bytes.withUnsafeMutableBufferPointer` then `bonus.withUnsafeMutableBufferPointer`
    /// from outside would trigger an overlapping-access error on the struct).
    @inlinable
    mutating func withMutableBuffers<R>(
        _ body: (UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int32>) -> R
    ) -> R {
        // Swap arrays into locals so the nested withUnsafeMutableBufferPointer
        // calls operate on independent variables, avoiding overlapping exclusive
        // accesses to `self` in library evolution mode. swap() is O(1) for arrays.
        var localBytes: [UInt8] = []
        var localBonus: [Int32] = []
        swap(&localBytes, &bytes)
        swap(&localBonus, &bonus)
        let result = localBytes.withUnsafeMutableBufferPointer { bytesPtr in
            localBonus.withUnsafeMutableBufferPointer { bonusPtr in
                body(bytesPtr.baseAddress!, bonusPtr.baseAddress!)
            }
        }
        swap(&localBytes, &bytes)
        swap(&localBonus, &bonus)
        return result
    }
}

/// State for edit distance dynamic programming computation.
///
/// Separated into its own struct to allow mutation while candidate storage is borrowed.
/// Uses three rows to support Damerau-Levenshtein transposition tracking with
/// zero-copy rotation via `swap()`.
///
/// ## Performance Note
///
/// A flat-buffer approach (`[row|prevRow|prevPrevRow]` in one `[Int]` accessed via
/// `withUnsafeMutableBufferPointer`) was benchmarked and caused ~11% regression:
/// the closure boundary prevents cross-function inlining of the ED functions into
/// `scoreImpl`, which outweighs the Array bounds-check savings.
@usableFromInline
internal struct EditDistanceState: Sendable {
    /// Dynamic programming row for edit distance computation.
    @usableFromInline var row: [Int]

    /// Previous row (i-1) for edit distance computation.
    @usableFromInline var prevRow: [Int]

    /// Row from two iterations ago (i-2) for Damerau-Levenshtein transposition tracking.
    @usableFromInline var prevPrevRow: [Int]

    /// Creates edit distance state with the specified initial capacity.
    @usableFromInline
    init(maxQueryLength: Int = 64) {
        self.row = [Int](repeating: 0, count: maxQueryLength + 1)
        self.prevRow = [Int](repeating: 0, count: maxQueryLength + 1)
        self.prevPrevRow = [Int](repeating: 0, count: maxQueryLength + 1)
    }

    /// Ensures the buffers have sufficient capacity.
    @inlinable
    mutating func ensureCapacity(_ queryLength: Int) {
        if row.count <= queryLength {
            row = [Int](repeating: 0, count: queryLength + 1)
            prevRow = [Int](repeating: 0, count: queryLength + 1)
            prevPrevRow = [Int](repeating: 0, count: queryLength + 1)
        }
    }

    /// Rotates DP rows for the next outer iteration.
    ///
    /// Equivalent to: `row ← old prevPrevRow, prevRow ← old row, prevPrevRow ← old prevRow`.
    /// Must be a method on `self` so Swift sees a single exclusive access
    /// (calling `swap(&state.row, &state.prevPrevRow)` from outside triggers
    /// an overlapping-access error).
    @inlinable
    mutating func rotateRows() {
        (row, prevRow, prevPrevRow) = (prevPrevRow, row, prevRow)
    }
}

/// State for the DP-optimal alignment computation.
///
/// Holds a reusable traceback matrix for the alignment DP. The actual DP rows
/// use `withUnsafeTemporaryAllocation` for stack allocation, so only the
/// traceback matrix needs persistent storage.
/// Separated into its own struct to allow mutation independently from candidate storage.
@usableFromInline
internal struct AlignmentState: Sendable {
    /// Flat traceback matrix (candidateLen * queryLen bytes).
    @usableFromInline var traceback: [UInt8]

    /// Width of the traceback matrix (= queryLen).
    @usableFromInline var tracebackWidth: Int

    /// Maximum candidate length for which traceback is allocated.
    @usableFromInline var maxTracebackCandidateLen: Int

    /// Creates alignment state with the specified initial capacity.
    @usableFromInline
    init(maxQueryLength: Int = 64, maxCandidateLength: Int = 128) {
        self.traceback = [UInt8](repeating: 0, count: maxCandidateLength * maxQueryLength)
        self.tracebackWidth = maxQueryLength
        self.maxTracebackCandidateLen = maxCandidateLength
    }

    /// Ensures the buffers have sufficient capacity.
    @inlinable
    mutating func ensureCapacity(queryLength: Int, candidateLength: Int) {
        if candidateLength <= 512 && (traceback.count < candidateLength * queryLength || tracebackWidth != queryLength) {
            traceback = [UInt8](repeating: 0, count: candidateLength * queryLength)
            tracebackWidth = queryLength
            maxTracebackCandidateLen = candidateLength
        }
    }
}

/// State for the Smith-Waterman local alignment DP computation.
///
/// Holds reusable integer arrays for the three-state (match/gap/consecutiveBonus) DP.
/// The buffer stores 3 rows, each `queryCapacity` Int32 elements wide:
/// - **match row**: Score if the current candidate position is matched consecutively
/// - **gap row**: Score if there's a gap before the current candidate position
/// - **bonus row**: Carried consecutive bonus from the start of the current match run
///
/// Diagonal values are carried as scalar variables during the inner loop,
/// so no row-swap logic is needed.
/// Separated from ``AlignmentState`` because it uses `[Int32]` instead of `[Double]`
/// and avoids wasted memory when only one algorithm mode is in use.
@usableFromInline
internal struct SmithWatermanState: Sendable {
    /// Flat buffer holding 3 rows: [match | gap | consecutiveBonus].
    @usableFromInline var buffer: [Int32]

    /// Width of each row in the flat buffer.
    @usableFromInline var queryCapacity: Int

    /// Creates Smith-Waterman state with the specified initial capacity.
    @usableFromInline
    init(maxQueryLength: Int = 64) {
        self.queryCapacity = maxQueryLength
        self.buffer = [Int32](repeating: 0, count: maxQueryLength * 3)
    }

    /// Ensures the buffers have sufficient capacity.
    @inlinable
    mutating func ensureCapacity(_ queryLength: Int) {
        if queryCapacity < queryLength {
            queryCapacity = queryLength
            buffer = [Int32](repeating: 0, count: queryLength * 3)
        }
    }
}

/// A reusable buffer for scoring operations to avoid allocations in the hot path.
///
/// `ScoringBuffer` holds pre-allocated arrays used during scoring.
/// By reusing the same buffer across multiple ``FuzzyMatcher/score(_:against:buffer:)``
/// calls, you eliminate heap allocations in the hot path.
///
/// ## Overview
///
/// Create a buffer using ``FuzzyMatcher/makeBuffer()`` and pass it by reference
/// to the `score` method. The buffer automatically expands if it encounters
/// strings longer than its initial capacity.
///
/// ## Example
///
/// ```swift
/// let matcher = FuzzyMatcher()
/// let query = matcher.prepare("config")
///
/// // Create a reusable buffer
/// var buffer = matcher.makeBuffer()
///
/// // Score many candidates with zero allocations
/// for candidate in candidates {
///     if let match = matcher.score(candidate, against: query, buffer: &buffer) {
///         print("\(candidate): \(match.score)")
///     }
/// }
/// ```
///
/// ## Concurrent Usage
///
/// For concurrent scoring, each task must have its own buffer. The buffer
/// itself is `Sendable`, but concurrent mutation is not safe.
///
/// ```swift
/// let matcher = FuzzyMatcher()
/// let query = matcher.prepare("data")
///
/// await withTaskGroup(of: Void.self) { group in
///     for chunk in chunks {
///         group.addTask {
///             // Each task creates its own buffer
///             var buffer = matcher.makeBuffer()
///
///             for candidate in chunk {
///                 matcher.score(candidate, against: query, buffer: &buffer)
///             }
///         }
///     }
/// }
/// ```
///
/// ## Memory Management
///
/// Buffers grow to accommodate the longest input seen and periodically shrink
/// when recent usage is much smaller than allocated capacity. After every
/// `shrinkCheckInterval` calls (default: 1000), if current capacity exceeds
/// 4x the high-water mark over that interval, the buffer shrinks to 2x the
/// high-water mark. This prevents unbounded memory growth in long-running
/// processes that occasionally see large inputs.
public struct ScoringBuffer: Sendable {
    /// Storage for the lowercased candidate bytes.
    @usableFromInline var candidateStorage: CandidateStorage

    /// State for edit distance dynamic programming.
    @usableFromInline var editDistanceState: EditDistanceState

    /// Buffer for storing match positions during alignment.
    @usableFromInline var matchPositions: [Int]

    /// State for DP-optimal alignment computation.
    @usableFromInline var alignmentState: AlignmentState

    /// Buffer for storing word-initial characters during acronym matching.
    @usableFromInline var wordInitials: [UInt8]

    /// State for Smith-Waterman local alignment DP computation.
    @usableFromInline var smithWatermanState: SmithWatermanState

    // MARK: - Shrink Policy

    @usableFromInline var highWaterCandidateLength: Int = 0
    @usableFromInline var highWaterQueryLength: Int = 0
    @usableFromInline var callsSinceLastCheck: Int = 0
    @usableFromInline var shrinkCheckInterval: Int = 1_000

    /// Creates a new scoring buffer with the specified initial capacity.
    ///
    /// The buffer will automatically expand if needed for longer strings.
    /// The default capacities are suitable for typical code identifiers.
    ///
    /// - Parameters:
    ///   - initialQueryCapacity: Initial capacity for query length. Default is `64`.
    ///   - initialCandidateCapacity: Initial capacity for candidate length. Default is `128`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default capacity (suitable for most use cases)
    /// var buffer = ScoringBuffer()
    ///
    /// // Larger capacity for long strings
    /// var largeBuffer = ScoringBuffer(initialQueryCapacity: 256, initialCandidateCapacity: 512)
    /// ```
    public init(initialQueryCapacity: Int = 64, initialCandidateCapacity: Int = 128) {
        self.candidateStorage = CandidateStorage(maxLength: initialCandidateCapacity)
        self.editDistanceState = EditDistanceState(maxQueryLength: initialQueryCapacity)
        self.matchPositions = [Int](repeating: 0, count: initialQueryCapacity)
        self.alignmentState = AlignmentState(maxQueryLength: initialQueryCapacity, maxCandidateLength: initialCandidateCapacity)
        self.wordInitials = [UInt8](repeating: 0, count: 32)
        self.smithWatermanState = SmithWatermanState(maxQueryLength: initialQueryCapacity)
    }

    /// Ensures the buffer has sufficient capacity for the given sizes.
    ///
    /// Called internally by ``FuzzyMatcher/score(_:against:buffer:)``.
    /// You typically don't need to call this directly.
    ///
    /// - Parameters:
    ///   - queryLength: Required capacity for query length.
    ///   - candidateLength: Required capacity for candidate length.
    @inlinable
    mutating func ensureCapacity(queryLength: Int, candidateLength: Int) {
        editDistanceState.ensureCapacity(queryLength)
        candidateStorage.ensureCapacity(candidateLength)
        if matchPositions.count < queryLength {
            matchPositions = [Int](repeating: 0, count: queryLength)
        }
        alignmentState.ensureCapacity(queryLength: queryLength, candidateLength: candidateLength)
    }

    /// Records the sizes of the current scoring operation for the shrink policy.
    @inlinable
    mutating func recordUsage(queryLength: Int, candidateLength: Int) {
        highWaterCandidateLength = max(highWaterCandidateLength, candidateLength)
        highWaterQueryLength = max(highWaterQueryLength, queryLength)
        callsSinceLastCheck += 1

        if callsSinceLastCheck >= shrinkCheckInterval {
            shrinkIfNeeded()
        }
    }

    /// Shrinks buffers if current capacity greatly exceeds recent usage.
    ///
    /// If capacity > 4x the high-water mark, shrinks to 2x the high-water mark.
    /// This is amortized over `shrinkCheckInterval` calls and not on the hot path.
    @inlinable
    mutating func shrinkIfNeeded() {
        let targetCandidate = max(128, highWaterCandidateLength * 2)
        let targetQuery = max(64, highWaterQueryLength * 2)

        if candidateStorage.bytes.count > highWaterCandidateLength * 4 {
            candidateStorage.bytes = [UInt8](repeating: 0, count: targetCandidate)
            candidateStorage.bonus = [Int32](repeating: 0, count: targetCandidate)
        }

        if editDistanceState.row.count > (highWaterQueryLength + 1) * 4 {
            editDistanceState.row = [Int](repeating: 0, count: targetQuery + 1)
            editDistanceState.prevRow = [Int](repeating: 0, count: targetQuery + 1)
            editDistanceState.prevPrevRow = [Int](repeating: 0, count: targetQuery + 1)
        }

        if matchPositions.count > highWaterQueryLength * 4 {
            matchPositions = [Int](repeating: 0, count: targetQuery)
        }

        if alignmentState.traceback.count > highWaterCandidateLength * highWaterQueryLength * 4 {
            alignmentState = AlignmentState(
                maxQueryLength: targetQuery,
                maxCandidateLength: targetCandidate
            )
        }

        if wordInitials.count > 128 {
            wordInitials = [UInt8](repeating: 0, count: 32)
        }

        if smithWatermanState.queryCapacity > highWaterQueryLength * 4 {
            smithWatermanState = SmithWatermanState(maxQueryLength: targetQuery)
        }

        // Reset tracking for next interval
        highWaterCandidateLength = 0
        highWaterQueryLength = 0
        callsSinceLastCheck = 0
    }

    // MARK: - Disjoint Property Access

    /// Provides simultaneous `inout` access to buffers needed by the edit distance pipeline.
    ///
    /// In library evolution mode, passing `&buffer.candidateStorage` and `&buffer.editDistanceState`
    /// as separate `inout` arguments triggers an overlapping-access error. This method provides
    /// a single exclusive access to `self` and projects its stored properties through a closure.
    @inline(__always)
    @inlinable
    mutating func withEditDistanceBuffers<R>(
        _ body: (
            inout CandidateStorage,
            inout EditDistanceState,
            inout [Int],
            inout AlignmentState,
            inout [UInt8]
        ) -> R
    ) -> R {
        withUnsafeMutablePointer(to: &self) { ptr in
            body(
                &ptr.pointee.candidateStorage,
                &ptr.pointee.editDistanceState,
                &ptr.pointee.matchPositions,
                &ptr.pointee.alignmentState,
                &ptr.pointee.wordInitials
            )
        }
    }

    /// Provides simultaneous `inout` access to buffers needed by the Smith-Waterman pipeline.
    ///
    /// In library evolution mode, passing `&buffer.candidateStorage` and `&buffer.smithWatermanState`
    /// as separate `inout` arguments triggers an overlapping-access error. This method provides
    /// a single exclusive access to `self` and projects its stored properties through a closure.
    @inline(__always)
    @inlinable
    mutating func withSmithWatermanBuffers<R>(
        _ body: (
            inout CandidateStorage,
            inout SmithWatermanState,
            inout [UInt8]
        ) -> R
    ) -> R {
        withUnsafeMutablePointer(to: &self) { ptr in
            body(
                &ptr.pointee.candidateStorage,
                &ptr.pointee.smithWatermanState,
                &ptr.pointee.wordInitials
            )
        }
    }
}
