# Getting Started with FuzzyMatch

Add FuzzyMatch to your project and start matching strings in minutes.

## Overview

FuzzyMatch offers two API levels: a **convenience API** for quick use and a **high-performance API** with zero-allocation hot paths for production workloads. Both produce identical results.

## Installation

Add FuzzyMatch to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ordo-one/FuzzyMatch.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "FuzzyMatch", package: "FuzzyMatch")
    ]
)
```

## Quick Start

### Convenience API

The fastest way to get started. Ideal for prototyping, small candidate sets, or when allocation overhead is not a concern:

```swift
import FuzzyMatch

let matcher = FuzzyMatcher()

// One-shot scoring — no buffer management needed
if let match = matcher.score("getUserById", against: "getUser") {
    print("score=\(match.score), kind=\(match.kind)")
}

// Top-N matches sorted by score
let query = matcher.prepare("config")
let top5 = matcher.topMatches(
    ["appConfig", "configManager", "database", "userConfig"],
    against: query,
    limit: 5
)

// All matches sorted by score
let all = matcher.matches(
    ["appConfig", "configManager", "database", "userConfig"],
    against: query
)
```

### High-Performance API (Recommended for Production)

For scoring many candidates, interactive search, or latency-sensitive paths. Uses the prepare-once, score-many pattern with reusable buffers to eliminate heap allocations in the scoring loop:

```swift
import FuzzyMatch

// 1. Create a matcher with default configuration
let matcher = FuzzyMatcher()

// 2. Prepare a query (precomputes bitmask, trigrams, etc.)
let query = matcher.prepare("getUser")

// 3. Create a reusable buffer (eliminates allocations in the scoring loop)
var buffer = matcher.makeBuffer()

// 4. Score candidates — zero heap allocations per call
let candidates = ["getUserById", "getUsername", "setUser", "fetchData"]
for candidate in candidates {
    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
        print("\(candidate): score=\(match.score), kind=\(match.kind)")
    }
}
```

For maximum throughput, use ``FuzzyMatcher/score(utf8:against:buffer:)`` with pre-extracted UTF-8 bytes. This `@inlinable` method enables cross-module inlining that the String overload cannot achieve on Swift 6.0, delivering ~60% higher throughput:

```swift
for var candidate in candidates {
    candidate.withUTF8 { utf8 in
        if let match = matcher.score(utf8: utf8, against: query, buffer: &buffer) {
            print("score=\(match.score)")
        }
    }
}
```

> Note: This performance gap is a Swift 6.0 limitation. When the library adopts Swift 6.2+ Span, the String API will recover full throughput and this method may be deprecated.

## Highlighting Matched Characters

After scoring, use ``FuzzyMatcher/attributedHighlight(_:against:applying:)-(_,FuzzyQuery,_)`` to get a styled `AttributedString` for UI display. Call this only for results you display — it is separate from the scoring hot path:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("mod")

// Score candidates first (high-performance path)
var buffer = matcher.makeBuffer()
let candidates = ["format:modern", "modification", "model_data"]
let matches = candidates.compactMap { c -> (String, ScoredMatch)? in
    matcher.score(c, against: query, buffer: &buffer).map { (c, $0) }
}

// Then highlight only the visible results
for (candidate, _) in matches.prefix(10) {
    if let text = matcher.attributedHighlight(candidate, against: query, applying: {
        $0.foregroundColor = .orange
    }) {
        // text is an AttributedString with matched chars styled
    }
}
```

On Linux or without SwiftUI, use Foundation-level attributes:

```swift
if let text = matcher.attributedHighlight("format:modern", against: query, applying: {
    $0.inlinePresentationIntent = .stronglyEmphasized
}) {
    // text has "mod" in bold
}
```

Both modes support highlighting. In edit distance mode, highlights include typo positions (substitutions, transpositions). In Smith-Waterman mode, multi-word queries highlight each word independently:

```swift
let swMatcher = FuzzyMatcher(config: .smithWaterman)

// Multi-word: each atom highlighted independently
if let text = swMatcher.attributedHighlight("fooXXXbar", against: "foo bar", applying: {
    $0.foregroundColor = .orange
}) {
    // "foo" and "bar" are styled, "XXX" is unstyled
}
```

For raw ranges, use ``FuzzyMatcher/highlight(_:against:)-(_,FuzzyQuery)`` which returns `[Range<String.Index>]?`. A convenience overload accepts a raw `String` query for both methods.

## Understanding Match Kinds

Every successful match includes a ``MatchKind`` that tells you where the query matched:

| Kind | Description | Example |
|------|-------------|---------|
| `.exact` | Query equals candidate (case-insensitive) | "user" matches "User" |
| `.prefix` | Query matches the beginning | "get" matches "getUserById" |
| `.substring` | Query matches somewhere within | "user" matches "getCurrentUser" |
| `.acronym` | Query matches word-initial characters | "bms" matches "Bristol-Myers Squibb" |
| `.alignment` | Query matched via Smith-Waterman local alignment | "gubi" matches "getUserById" |

In edit distance mode, prefix matches receive a configurable boost via ``EditDistanceConfig/prefixWeight``, and acronym matches use ``EditDistanceConfig/acronymWeight``. In Smith-Waterman mode, all matches return as `.alignment`.

## Concurrent Usage

``FuzzyMatcher`` and ``FuzzyQuery`` are immutable and `Sendable` — share them freely across threads. Each thread needs its own ``ScoringBuffer``:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("getData")
let candidates = loadLargeCandidateList()

let workerCount = 8
let chunkSize = (candidates.count + workerCount - 1) / workerCount

await withTaskGroup(of: [ScoredMatch].self) { group in
    for start in stride(from: 0, to: candidates.count, by: chunkSize) {
        let end = min(start + chunkSize, candidates.count)
        let chunk = candidates[start..<end]
        group.addTask {
            var buffer = matcher.makeBuffer()  // one buffer per task
            return chunk.compactMap { candidate in
                matcher.score(candidate, against: query, buffer: &buffer)
            }
        }
    }
    for await taskMatches in group {
        // Collect results...
    }
}
```

## Filtering and Sorting Results

Using the convenience API:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("config")

// Get all matches sorted by score
let sorted = matcher.matches(
    ["configuration", "ConfigManager", "user_config", "settings"],
    against: query
)
for result in sorted {
    print("\(result.candidate): \(result.match.score)")
}

// Or just the top 3
let top3 = matcher.topMatches(
    ["configuration", "ConfigManager", "user_config", "settings"],
    against: query,
    limit: 3
)
```

Or using the high-performance API for zero-allocation control:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("config")
var buffer = matcher.makeBuffer()

let candidates = ["configuration", "ConfigManager", "user_config", "settings"]

let results = candidates.compactMap { candidate -> (String, ScoredMatch)? in
    guard let match = matcher.score(candidate, against: query, buffer: &buffer) else {
        return nil
    }
    return (candidate, match)
}

let sorted = results.sorted { $0.1.score > $1.1.score }
for (candidate, match) in sorted {
    print("\(candidate): \(match.score)")
}
```

## Customizing Configuration

Use ``MatchConfig`` to tune matching behavior for your use case:

```swift
// Strict autocomplete: few typos, prefer prefixes (edit distance mode)
let config = MatchConfig(
    minScore: 0.6,
    algorithm: .editDistance(EditDistanceConfig(
        maxEditDistance: 1,
        prefixWeight: 2.0
    ))
)
let matcher = FuzzyMatcher(config: config)

// Smith-Waterman mode with custom gap penalty
let swConfig = MatchConfig(
    algorithm: .smithWaterman(SmithWatermanConfig(penaltyGapStart: 5))
)
let swMatcher = FuzzyMatcher(config: swConfig)
```

See ``MatchConfig``, ``EditDistanceConfig``, and ``SmithWatermanConfig`` for the full list of tunable parameters.
