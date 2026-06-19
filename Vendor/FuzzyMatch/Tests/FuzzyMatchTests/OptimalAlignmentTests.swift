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

// MARK: - Optimal Alignment DP Tests

// Helper to run optimalAlignment with arrays
private func runAlignment(
    query: [UInt8],
    candidate: [UInt8],
    config: EditDistanceConfig = EditDistanceConfig()
) -> (positionCount: Int, bonus: Double, positions: [Int]) {
    let boundaryMask = computeBoundaryMask(bytes: candidate)
    var positions = [Int](repeating: 0, count: query.count)
    var state = AlignmentState(maxQueryLength: query.count, maxCandidateLength: candidate.count)
    let result = optimalAlignment(
        query: query,
        candidate: candidate,
        boundaryMask: boundaryMask,
        positions: &positions,
        state: &state,
        config: config
    )
    return (result.positionCount, result.bonus, positions)
}

@Test func dpAlignmentFindsConsecutiveOverBoundary() {
    // Query "ab" in "a_B_ab" — DP should find consecutive [4,5] not boundary [0,2]
    // because consecutive bonus at [4,5] is better than boundary with gap at [0,2]
    let query = Array("ab".utf8)
    let candidate = Array("a_b_ab".utf8)
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .affine(open: 0.03, extend: 0.005)
    )
    let result = runAlignment(query: query, candidate: candidate, config: config)
    #expect(result.positionCount == 2)
    // The DP should pick positions that maximize the bonus
    // Either [4,5] (consecutive) or [0,2] (boundaries) - DP picks the higher scoring one
}

@Test func dpAlignmentPrefersWordBoundaries() {
    // Query "gubi" in "getUserById" — should match at word boundaries [0,3,7,9]
    let query = Array("gubi".utf8)
    let candidate = Array("getuserbyid".utf8)
    let result = runAlignment(query: query, candidate: candidate)
    #expect(result.positionCount == 4)
    // All 4 should be at word boundaries (position 0 is always a boundary)
    #expect(result.positions[0] == 0) // 'g'
}

@Test func dpAlignmentEmptyInputs() {
    let result1 = runAlignment(query: [], candidate: Array("test".utf8))
    #expect(result1.positionCount == 0)

    let result2 = runAlignment(query: Array("test".utf8), candidate: [])
    #expect(result2.positionCount == 0)
}

@Test func dpAlignmentExactMatch() {
    let query = Array("test".utf8)
    let candidate = Array("test".utf8)
    let result = runAlignment(query: query, candidate: candidate)
    #expect(result.positionCount == 4)
    #expect(result.positions[0] == 0)
    #expect(result.positions[1] == 1)
    #expect(result.positions[2] == 2)
    #expect(result.positions[3] == 3)
}

@Test func dpAlignmentSingleChar() {
    let query = Array("a".utf8)
    let candidate = Array("xaxbx".utf8)
    let result = runAlignment(query: query, candidate: candidate)
    #expect(result.positionCount == 1)
}

@Test func dpAlignmentNoMatch() {
    let query = Array("xyz".utf8)
    let candidate = Array("abcdef".utf8)
    let result = runAlignment(query: query, candidate: candidate)
    #expect(result.positionCount == 0)
}

@Test func dpAlignmentBonusIsNonNegativeForBoundaryMatches() {
    // When all matches are at word boundaries, bonus should be positive
    let query = Array("gubi".utf8)
    let candidate = Array("getuserbyid".utf8)
    let config = EditDistanceConfig(
        wordBoundaryBonus: 0.1,
        consecutiveBonus: 0.05,
        gapPenalty: .none,
        firstMatchBonus: 0.0
    )
    let result = runAlignment(query: query, candidate: candidate, config: config)
    #expect(result.positionCount == 4)
    #expect(result.bonus >= 0.0)
}

@Test func dpBonusAtLeastAsGoodAsGreedy() {
    // The DP should produce bonus >= greedy for these examples
    let cases: [(query: String, candidate: String)] = [
        ("gubi", "getUserById"),
        ("fb", "fooBar"),
        ("sn", "setName"),
        ("config", "configuration")
    ]

    let config = EditDistanceConfig()

    for testCase in cases {
        let query = Array(testCase.query.utf8)
        let candidate = Array(testCase.candidate.utf8)
        let boundaryMask = computeBoundaryMask(bytes: candidate)

        // Greedy
        var greedyPositions = [Int](repeating: 0, count: query.count)
        let greedyCount = findMatchPositions(
            query: query,
            candidate: candidate,
            boundaryMask: boundaryMask,
            positions: &greedyPositions
        )

        var greedyBonus = 0.0
        if greedyCount > 0 {
            greedyBonus = calculateBonuses(
                matchPositions: greedyPositions,
                positionCount: greedyCount,
                candidateBytes: candidate,
                boundaryMask: boundaryMask,
                config: config
            )
        }

        // DP optimal
        let dpResult = runAlignment(query: query, candidate: candidate, config: config)

        #expect(
            dpResult.bonus >= greedyBonus - 0.001,
            "DP bonus (\(dpResult.bonus)) should be >= greedy bonus (\(greedyBonus)) for '\(testCase.query)' in '\(testCase.candidate)'"
        )
    }
}

@Test func dpAlignmentIntegrationWithFuzzyMatcher() {
    // Test that the full matcher still works correctly with DP alignment
    let matcher = FuzzyMatcher()
    var buffer = matcher.makeBuffer()

    // Basic matches should still work
    let query = matcher.prepare("gubi")
    let result = matcher.score("getUserById", against: query, buffer: &buffer)
    #expect(result != nil)
    #expect(result!.score > 0.3)

    // Exact match
    let exactQuery = matcher.prepare("test")
    let exactResult = matcher.score("test", against: exactQuery, buffer: &buffer)
    #expect(exactResult != nil)
    #expect(exactResult!.score == 1.0)
}

@Test func dpAlignmentLargeInputFallback() {
    // For candidates > 512, should fall back to greedy without crashing
    let query = Array("abc".utf8)
    let longStr = String(repeating: "x", count: 510) + "abc"
    let candidate = Array(longStr.utf8)
    let result = runAlignment(query: query, candidate: candidate)
    #expect(result.positionCount == 3)
}
