import Foundation

enum FuzzyMatcher {
    /// Returns a match score for the given query against the target string.
    /// Both strings should be lowercased before calling.
    /// Returns 0.0 for no match, up to 1.0 for exact match.
    static func score(query: String, in target: String) -> Double {
        guard !query.isEmpty else { return 0 }
        if target == query { return 1.0 }
        if target.hasPrefix(query) { return 0.95 }

        let queryChars = Array(query)
        let targetChars = Array(target)
        var queryIndex = 0
        var previousMatchIndex = -1
        var rawScore = 0.0
        let wordBoundaries: Set<Character> = [" ", "-", "_", ".", "/"]

        for (targetIndex, char) in targetChars.enumerated() {
            guard queryIndex < queryChars.count else { break }
            guard char == queryChars[queryIndex] else { continue }

            if previousMatchIndex >= 0 {
                let gap = targetIndex - previousMatchIndex - 1
                if gap == 0 {
                    rawScore += 3
                } else {
                    rawScore -= Double(gap)
                }
            }

            if targetIndex == 0 || wordBoundaries.contains(targetChars[targetIndex - 1]) {
                rawScore += 5
            }

            rawScore += 1
            previousMatchIndex = targetIndex
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return 0 }

        let maxPossible = Double(queryChars.count) * 9
        let normalized = max(0, rawScore) / maxPossible
        return min(normalized, 0.85)
    }
}
