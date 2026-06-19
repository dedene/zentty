# ``FuzzyMatch``

High-performance fuzzy string matching for Swift.

## Overview

FuzzyMatch provides configurable fuzzy string matching with two matching modes — **Damerau-Levenshtein edit distance** (default, penalty-driven) and **Smith-Waterman local alignment** (bonus-driven) — both with multi-stage prefiltering and zero-allocation hot paths. It handles typos (insertions, deletions, substitutions, and transpositions), supports prefix, substring, acronym, and alignment matching, and uses intelligent scoring bonuses for intuitive ranking.

Originally developed for searching financial instrument databases (stock tickers, fund names, ISINs), the library is equally well suited to code identifiers, file names, product catalogs, contact lists, and any other domain where typo tolerance, fast performance, and sensible ranking are important.

### Convenience API

The simplest way to get started — ideal for prototyping or small candidate sets:

```swift
import FuzzyMatch

let matcher = FuzzyMatcher()

// One-shot scoring
if let match = matcher.score("getUserById", against: "getUser") {
    print("score=\(match.score), kind=\(match.kind)")
}

// Top-N matching
let query = matcher.prepare("config")
let top3 = matcher.topMatches(
    ["appConfig", "configManager", "database", "userConfig"],
    against: query,
    limit: 3
)
```

### High-Performance API

For production use, interactive search, and batch processing — zero heap allocations per `score` call:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("getUser")
var buffer = matcher.makeBuffer()

let candidates = ["getUserById", "getUsername", "setUser", "fetchData"]
for candidate in candidates {
    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
        print("\(candidate): score=\(match.score), kind=\(match.kind)")
    }
}
// getUserById: score=0.9988, kind=prefix
// getUsername: score=0.9988, kind=prefix
// setUser: score=0.9047619047619048, kind=prefix
```

For maximum throughput, use `score(utf8:against:buffer:)` with pre-extracted UTF-8 bytes. This `@inlinable` method enables cross-module inlining that the String overload cannot achieve on Swift 6.0, delivering ~60% higher throughput:

```swift
for var candidate in candidates {
    candidate.withUTF8 { utf8 in
        if let match = matcher.score(utf8: utf8, against: query, buffer: &buffer) {
            print("score=\(match.score)")
        }
    }
}
```

> Note: This performance gap is a Swift 6.0 limitation. When the library adopts Swift 6.2+ Span, the String API will recover full throughput.

### Highlighting Matched Characters

After scoring, call `attributedHighlight(_:against:applying:)` on visible results to get a styled `AttributedString` for UI display. This is separate from scoring — call it only for the results you actually display:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("mod")

if let text = matcher.attributedHighlight("format:modern", against: query, applying: {
    $0.foregroundColor = .orange
}) {
    // text has "mod" styled in orange
}
```

For raw ranges, use `highlight(_:against:)` which returns `[Range<String.Index>]?`. In edit distance mode, highlights handle typos — substituted positions and transpositions are included. In Smith-Waterman mode, multi-word queries highlight each word independently.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AlgorithmOverview>
- <doc:QualityAndPerformance>

### Core Types

- ``FuzzyMatcher``
- ``FuzzyQuery``
- ``ScoringBuffer``

### Configuration

- ``MatchConfig``
- ``MatchingAlgorithm``
- ``EditDistanceConfig``
- ``SmithWatermanConfig``
- ``GapPenalty``

### Results

- ``ScoredMatch``
- ``MatchResult``
- ``MatchKind``
