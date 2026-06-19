# Algorithm & Architecture

How FuzzyMatch turns a query and candidate into a ranked score.

## Overview

FuzzyMatch supports two matching algorithms — **Edit Distance** (default) and **Smith-Waterman** — both sharing the same prefilter pipeline and zero-allocation architecture. The algorithm is selected via ``MatchConfig/algorithm``.

### Edit Distance Pipeline

```
Candidate → Length Filter → Bitmask Filter → Trigram Filter → Edit Distance
                                                                    ↓
                                                            Position Finding
                                                                    ↓
                                              Bonus Calculation (boundaries, consecutive, gaps)
                                                                    ↓
                                                         Subsequence Fallback
                                                                    ↓
                                                          Acronym Matching
                                                                    ↓
                                                              Final Score
```

If edit distance matching fails (too many edits), a subsequence matching fallback handles abbreviation-style queries like "gubi" → "getUserById". Acronym matching then checks if the query matches word-initial characters (e.g., "bms" → "Bristol-Myers Squibb").

### Smith-Waterman Pipeline

```
Candidate → Bitmask Filter (tolerance 0) → Lowercase + Bonus Precomputation
                                                         ↓
                                              Smith-Waterman DP (single pass)
                                                         ↓
                                                  Acronym Fallback
                                                         ↓
                                              Normalize to 0.0–1.0
```

Smith-Waterman uses a single DP pass where each matched character earns points with bonuses for word boundaries, camelCase, and consecutive runs, minus affine gap penalties. Multi-word queries are split into atoms scored independently with AND semantics.

## Damerau-Levenshtein Edit Distance

The core algorithm measures the minimum number of single-character edits to transform one string into another:

| Operation | Example | Cost |
|-----------|---------|------|
| Insertion | "cat" → "cart" | 1 |
| Deletion | "cart" → "cat" | 1 |
| Substitution | "cat" → "bat" | 1 |
| Transposition | "teh" → "the" | 1 |

Standard Levenshtein treats transpositions as two operations. Damerau-Levenshtein recognizes that swapping adjacent characters is a common typo and counts it as one edit — studies show ~80% of human spelling errors are single-character edits.

The implementation uses a rolling-array dynamic programming approach with three rows (current, previous, and two-back for transpositions), reducing space from O(nm) to O(m).

### Prefix and Substring Matching

FuzzyMatch supports two edit distance modes:

- **Prefix**: Matches the query against the beginning of the candidate. Trailing candidate characters are ignored.
- **Substring**: Matches the query anywhere within the candidate by resetting the DP row at each position.

The scorer tries prefix first, falls back to substring if the prefix score is weak (below 0.7).

## Three-Stage Prefiltering

Computing edit distance is O(nm), so FuzzyMatch uses fast prefilters to reject most candidates cheaply.

### Stage 1: Length Bounds — O(1)

If the candidate is shorter than `queryLength - effectiveMaxEditDistance`, it would require more deletions than allowed. The `effectiveMaxEditDistance` is tightened for short queries (e.g., a 4-char query with `maxEditDistance=2` gets an effective value of 1). No upper bound is enforced to support subsequence matching of short queries against long candidates.

### Stage 2: Character Bitmask — O(1)

A 64-bit bitmask tracks character presence (a-z, 0-9, underscore, plus 2-byte UTF-8 characters hashed into the upper bits). The number of distinct missing character types must be within an adaptive tolerance:

```
missingChars = queryMask & ~candidateMask
bitmaskTolerance = queryLength <= 3 ? 0 : effectiveMaxEditDistance
pass = (popcount(missingChars) <= bitmaskTolerance)
```

For queries of 4+ characters, this allows substitution typos (where a character in the query is replaced by a different character in the candidate) while still quickly rejecting candidates that are too different. For example, "hein" can match "heia" (one missing character type, within `bitmaskTolerance` of 1) but a query with three missing character types would be rejected.

For very short queries (≤3 characters), the tolerance is 0 (strict): with only 1-3 distinct character types, allowing even one missing type lets nearly everything through, defeating the purpose of the prefilter. This means substitution typos (e.g., "UES" for "USD") are not detected for short queries, but transposition typos (e.g., "UDS" for "USD") still work because they involve the same character set.

### Stage 3: Trigram Similarity — O(n)

Trigrams are consecutive 3-character sequences. The candidate must share at least `queryTrigramCount - 3 * effectiveMaxEditDistance` trigrams with the query. Each edit can destroy up to 3 trigrams (a transposition at position i affects trigrams at i-2..i, i-1..i+1, and i..i+2), hence the factor of 3. This filter is only applied for queries of 4+ characters whose trigram count exceeds the tolerance threshold. Space-containing trigrams are excluded at computation time, so multi-word queries still pass through the filter.

## Scoring Model

### Base Score

Edit distance is converted to a 0.0–1.0 score:

```
baseScore = max(0, 1.0 - editDistance / queryLength)
```

### Match Type Weighting

An asymptotic formula boosts prefix matches while ensuring perfect matches always score 1.0 and imperfect matches always stay below 1.0:

```
weightedScore = max(0, 1.0 - (1.0 - baseScore) / weight)
```

### Scoring Bonuses

Position-based bonuses improve ranking quality:

- **Word boundary bonus** — Rewards matches at camelCase transitions, underscores, and digit boundaries. Query "gubi" matching "getUserById" at positions g, U, B, I gets 4 × 0.1 = 0.4 bonus.
- **Consecutive bonus** — Rewards sequential character matches. "get" matching positions 0, 1, 2 gets 2 × 0.05 = 0.1 bonus.
- **Gap penalty** — Penalizes scattered matches. The default affine model charges more to *start* a gap than to continue one, encouraging either tight matches or accepting larger structural gaps.
- **First match position bonus** — Rewards matches starting early in the candidate, decaying linearly from full value at position 0 to zero at `firstMatchBonusRange`.
- **Contiguous substring recovery** — For short queries (2–4 chars), when the greedy position finder returns scattered positions but an exact contiguous match exists, a full scan replaces the positions with the actual contiguous occurrence, preferring whole-word-bounded positions. This ensures short keyword queries like "SRI" find the actual word "SRI" at position 16 in "iShares MSCI EM SRI" rather than scattering across "i**s**ha**r**es msc**i**".
- **Whole-word substring recovery** — When a substring match is an exact, complete word (bounded by word boundaries or string edges on both sides), a portion of the length penalty is recovered using `min(lengthPenalty × 0.8, 0.15)`. This mirrors the exact prefix recovery and ensures that, for example, "SRI" as a standalone word in a long candidate beats "SERVICENOW" (shorter but mid-word match).

All bonuses are computed using a DP-optimal alignment that considers word boundaries, consecutive runs, and gaps simultaneously to find the best possible positioning.

## Subsequence Matching Fallback

When edit distance exceeds the threshold, FuzzyMatch tries subsequence matching: finding all query characters in order within the candidate, preferring word boundary positions. This handles abbreviation patterns like "gubi" → "**g**et**U**ser**B**y**I**d".

The subsequence score is based on the gap ratio between matched positions, with the same bonuses applied on top.

## Acronym Matching

When both edit distance and subsequence matching fail to produce strong results, FuzzyMatch tries acronym matching as a final pass. This handles abbreviation-style queries where users type the first letter of each word in a multi-word name (e.g., "bms" → "Bristol-Myers Squibb").

The acronym pass:
1. Checks the candidate has at least 3 words (via `popcount(boundaryMask)` — O(1) early exit)
2. Extracts the first character of each word using the precomputed boundary mask
3. Verifies the query is a subsequence of the initials
4. Scores by coverage: `score = (0.55 + 0.4 × coverage) × acronymWeight`

Where `coverage = queryLength / initialCount`. Full coverage (all initials matched) scores 0.95; partial coverage scales down proportionally. This pass runs only for queries of 2–8 characters.

## Smith-Waterman Local Alignment

The Smith-Waterman mode uses a bonus-driven approach inspired by nucleo and fzf: instead of measuring how many edits are needed, it finds the optimal local alignment of query characters within the candidate and scores it based on match quality.

### Integer DP

The inner loop uses Int32 arithmetic exclusively, avoiding floating-point in the hot path. Three parallel rows track:

- **Match row** — Score if the current candidate position is matched consecutively
- **Gap row** — Score if there's a gap before the current candidate position
- **Bonus row** — Carried consecutive bonus from the start of the current match run

Diagonal values are carried as scalar variables during the inner loop, so no row-swap logic is needed.

### Scoring Model

Each matched character earns ``SmithWatermanConfig/scoreMatch`` points (default: 16). Bonuses are added based on position context:

| Bonus | Default | Trigger |
|-------|---------|---------|
| Whitespace boundary | 10 | After space/tab, or position 0 |
| Delimiter boundary | 9 | After `/`, `:`, `;`, `\|` |
| General boundary | 8 | After non-alphanumeric characters |
| camelCase transition | 5 | Lowercase → uppercase or non-digit → digit |
| Consecutive | 4 | Adjacent matched characters |
| First char multiplier | 2× | Applied to the first matched character's bonus |

Gaps incur affine penalties: ``SmithWatermanConfig/penaltyGapStart`` (default: 3) to open, ``SmithWatermanConfig/penaltyGapExtend`` (default: 1) per additional character.

### Consecutive Bonus Propagation

When characters match consecutively at a word boundary, the boundary bonus is carried forward through the entire consecutive run (nucleo-style). This makes boundary-aligned runs significantly more valuable than scattered boundary matches.

### Multi-Word Atom Splitting

When ``SmithWatermanConfig/splitSpaces`` is `true` (default), queries containing spaces are split into independent atoms. Each atom is scored separately against the candidate with AND semantics — all atoms must match for a result. This handles queries like "johnson johnson" or "ishares treasury" naturally.

### Normalization

The raw integer score is normalized to 0.0–1.0 by dividing by a theoretical maximum (the score a perfect query-length match would achieve with full boundary bonuses and consecutive runs). This ensures scores are comparable across different query lengths.

### Acronym Fallback

For single-word queries of 2–8 characters, Smith-Waterman mode includes an acronym fallback that competes with the DP score. If the acronym score is higher, it wins. This ensures abbreviation queries like "bms" → "Bristol-Myers Squibb" work in both modes.

## Choosing a Matching Mode

| Factor | Edit Distance | Smith-Waterman |
|--------|--------------|----------------|
| Typo tolerance | Excellent (Damerau-Levenshtein) | Limited (no edit distance) |
| Multi-word queries | Basic (single alignment) | Excellent (atom splitting) |
| Throughput | Good (~26M/sec) | Higher (~44M/sec) |
| Match types | exact, prefix, substring, acronym | alignment, acronym |
| Scoring model | Penalty-driven (distance → score) | Bonus-driven (alignment → score) |
| Best for | Autocomplete, typo-tolerant search | Code/file search, high throughput |

## Complexity

| Operation | Time | Space |
|-----------|------|-------|
| Query preparation | O(q) | O(q) |
| Length + bitmask filter | O(1) | O(1) |
| Trigram filter | O(c) | O(1) |
| Edit distance | O(q × c) | O(q) |
| ED bonus calculation | O(q × c) | O(q × c) |
| Smith-Waterman DP | O(q × c) | O(q) |
| Acronym matching | O(c) | O(1) |

Where q = query length, c = candidate length. In practice, prefilters reject most candidates in O(1), so the amortized cost per candidate is very low.
