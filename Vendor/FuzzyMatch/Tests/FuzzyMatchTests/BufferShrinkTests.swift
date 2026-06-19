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

// MARK: - Buffer Shrink Policy Tests

@Test func bufferGrowsForLargeInput() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Initial capacity is 128 for candidate
    #expect(buffer.candidateStorage.bytes.count == 128)

    // Score a large candidate to force growth (use 3-char query to avoid tiny query fast path)
    let largeCandidate = String(repeating: "a", count: 300)
    let query = matcher.prepare("aaa")
    _ = matcher.score(largeCandidate, against: query, buffer: &buffer)

    #expect(buffer.candidateStorage.bytes.count >= 300)
}

@Test func bufferShrinksAfterManySmallInputs() {
    var buffer = ScoringBuffer()
    // Set a small interval for testing
    buffer.shrinkCheckInterval = 10

    // First, grow the buffer with a large input
    buffer.ensureCapacity(queryLength: 200, candidateLength: 1_000)
    #expect(buffer.candidateStorage.bytes.count >= 1_000)
    #expect(buffer.editDistanceState.row.count >= 201)

    // Record usage of small inputs
    for _ in 0..<10 {
        buffer.recordUsage(queryLength: 5, candidateLength: 20)
    }

    // After 10 calls (= shrinkCheckInterval), shrink should have been triggered
    // Capacity 1000 > 4 * 20 (high water = 20), so should shrink to 2 * 20 = 40
    // But minimum is 128 for candidate
    #expect(buffer.candidateStorage.bytes.count <= 128, "Candidate buffer should have shrunk. Actual: \(buffer.candidateStorage.bytes.count)")
}

@Test func bufferDoesNotShrinkWhenCapacityIsAppropriate() {
    var buffer = ScoringBuffer()
    buffer.shrinkCheckInterval = 10

    // Use inputs that match the default capacity (128 candidate, 64 query)
    for _ in 0..<10 {
        buffer.recordUsage(queryLength: 50, candidateLength: 100)
    }

    // Default capacity of 128 is not > 4 * 100 = 400, so no shrink
    #expect(buffer.candidateStorage.bytes.count == 128)
}

@Test func bufferShrinkDoesNotAffectCorrectness() {
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()
    buffer.shrinkCheckInterval = 5

    let query = matcher.prepare("test")

    // Score a large candidate first (use moderate padding so length penalty
    // doesn't push score below minScore)
    let large = String(repeating: "x", count: 100) + "test"
    let result1 = matcher.score(large, against: query, buffer: &buffer)
    #expect(result1 != nil)

    // Score many small candidates to trigger shrink
    for _ in 0..<10 {
        _ = matcher.score("test", against: query, buffer: &buffer)
    }

    // Score again after potential shrink — should still produce correct results
    let result2 = matcher.score("test", against: query, buffer: &buffer)
    #expect(result2 != nil)
    #expect(result2?.score == 1.0)

    let result3 = matcher.score("testing", against: query, buffer: &buffer)
    #expect(result3 != nil)
}

@Test func highWaterMarkTracksMaximum() {
    var buffer = ScoringBuffer()
    buffer.shrinkCheckInterval = 100 // Won't trigger shrink during test

    buffer.recordUsage(queryLength: 10, candidateLength: 50)
    #expect(buffer.highWaterCandidateLength == 50)
    #expect(buffer.highWaterQueryLength == 10)

    buffer.recordUsage(queryLength: 5, candidateLength: 100)
    #expect(buffer.highWaterCandidateLength == 100)
    #expect(buffer.highWaterQueryLength == 10)

    buffer.recordUsage(queryLength: 20, candidateLength: 30)
    #expect(buffer.highWaterCandidateLength == 100)
    #expect(buffer.highWaterQueryLength == 20)
}

@Test func shrinkResetsTracking() {
    var buffer = ScoringBuffer()
    buffer.shrinkCheckInterval = 5

    // Record several usages
    for _ in 0..<5 {
        buffer.recordUsage(queryLength: 10, candidateLength: 50)
    }

    // After shrinkCheckInterval calls, tracking should be reset
    #expect(buffer.callsSinceLastCheck == 0)
    #expect(buffer.highWaterCandidateLength == 0)
    #expect(buffer.highWaterQueryLength == 0)
}
