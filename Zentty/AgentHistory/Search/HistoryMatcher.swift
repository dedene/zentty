import Foundation

/// How well one occurrence of a term sits in the text. Ordered worst to best.
enum HistoryMatchClass: Comparable, Sendable {
    /// No credit: a short mid-word hit, or a mid-word hit inside a hash or UUID.
    case none
    /// Starts inside a word (terms of four or more scalars only).
    case midWord
    /// Starts at a word boundary, ends inside a word.
    case prefix
    /// Word boundaries on both sides.
    case word

    var credit: Double {
        switch self {
        case .none: 0
        case .midWord: 0.3
        case .prefix: 0.8
        case .word: 1.0
        }
    }
}

/// One credited occurrence of `HistoryQuery.terms[termIndex]`, as UTF-8 byte offsets into the
/// folded text.
struct HistoryTermOccurrence: Equatable, Sendable {
    let termIndex: Int
    let bytes: Range<Int>
    let matchClass: HistoryMatchClass
}

struct HistoryGrade: Equatable, Sendable {
    /// Mean of each term's best credit.
    let baseQuality: Double
    /// `baseQuality` plus the phrase (+0.25) or proximity (+0.1) bonus.
    let quality: Double
    /// `baseQuality >= 0.8`: every term is, on average, at least a word prefix. Word-level
    /// sessions always rank above mid-word-only ones.
    let isWordLevel: Bool
    /// Every credited occurrence, sorted by position; empty unless requested.
    let occurrences: [HistoryTermOccurrence]
}

/// Grades a candidate text against a query's terms. Inputs are folded with
/// `AgentHistorySearchText` (the shared ingest/query fold), so matching is plain byte search.
///
/// Rules:
/// - Every occurrence of every term is found with `memmem`; the best class per term wins.
/// - A word character is a letter or digit that is not CJK. CJK scalars, punctuation, symbols
///   and spaces are boundaries, so a term inside running CJK text is a whole word.
/// - Boundaries on both sides: `.word` (1.0). Left only: `.prefix` (0.8). Otherwise
///   `.midWord` (0.3) for terms of four or more scalars, unless the occurrence sits inside a
///   hex-like token: within the enclosing `[0-9a-z-]` run, a `-`-separated segment of seven or
///   more hex digits, or an 8-4-4-4-12 UUID. A term that starts (ends) with a non-word
///   character never needs a boundary on that side.
/// - Any term without credit fails the candidate (`nil`).
/// - With two or more terms: +0.25 when the terms appear in typed order as `phraseText`,
///   else +0.1 when one occurrence of every term fits in a window of at most 60 bytes.
enum HistoryMatcher {
    /// `.path` is for artifact values. Path delimiters (`/ . - _ \`) are not word characters,
    /// so a segment boundary already is a word boundary; both modes grade alike today, and
    /// path-only boundary rules belong here.
    enum BoundaryMode: Sendable {
        case text, path
    }

    static let phraseBonus = 0.25
    static let proximityBonus = 0.1
    static let proximityWindowBytes = 60
    static let wordLevelThreshold = 0.8
    static let minimumMidWordScalars = 4

    static func grade(
        normalizedUTF8: UnsafeBufferPointer<UInt8>,
        query: HistoryQuery,
        mode: BoundaryMode = .text,
        collectOccurrences: Bool = false
    ) -> HistoryGrade? {
        grade(
            normalizedUTF8: normalizedUTF8,
            terms: query.terms,
            phraseText: query.phraseText,
            mode: mode,
            collectOccurrences: collectOccurrences
        )
    }

    static func grade(normalized: String, query: HistoryQuery, mode: BoundaryMode = .text) -> HistoryGrade? {
        withUTF8(normalized) { grade(normalizedUTF8: $0, query: query, mode: mode) }
    }

    /// Grades against an explicit term list (for callers that grade term subsets, such as a
    /// per-field metadata pass). `phraseText` is only used with two or more terms.
    static func grade(
        normalizedUTF8 text: UnsafeBufferPointer<UInt8>,
        terms: [HistoryQueryTerm],
        phraseText: String?,
        mode: BoundaryMode = .text,
        collectOccurrences: Bool = false
    ) -> HistoryGrade? {
        guard !terms.isEmpty, !text.isEmpty else {
            return nil
        }

        var phraseFound = false
        if terms.count >= 2, let phraseText, !phraseText.isEmpty {
            let phrase = PreparedTerm(text: phraseText)
            forEachCreditedOccurrence(of: phrase, in: text, mode: mode) { _, _ in
                phraseFound = true
                return false
            }
        }

        let needsPositions = collectOccurrences || (terms.count >= 2 && !phraseFound)
        var creditSum = 0.0
        var rangesPerTerm: [[Range<Int>]] = []
        var occurrences: [HistoryTermOccurrence] = []
        if needsPositions {
            rangesPerTerm.reserveCapacity(terms.count)
        }

        for (index, term) in terms.enumerated() {
            let prepared = PreparedTerm(term)
            var best = HistoryMatchClass.none
            var ranges: [Range<Int>] = []
            forEachCreditedOccurrence(of: prepared, in: text, mode: mode) { range, matchClass in
                if matchClass > best {
                    best = matchClass
                }
                if needsPositions {
                    ranges.append(range)
                    if collectOccurrences {
                        occurrences.append(HistoryTermOccurrence(termIndex: index, bytes: range, matchClass: matchClass))
                    }
                    return true
                }
                return best != .word
            }
            guard best != .none else {
                return nil
            }
            creditSum += best.credit
            if needsPositions {
                rangesPerTerm.append(ranges)
            }
        }

        let baseQuality = creditSum / Double(terms.count)
        var quality = baseQuality
        if phraseFound {
            quality += phraseBonus
        } else if terms.count >= 2, hasCoveringWindow(rangesPerTerm, within: proximityWindowBytes) {
            quality += proximityBonus
        }

        if collectOccurrences {
            occurrences.sort {
                ($0.bytes.lowerBound, $0.termIndex) < ($1.bytes.lowerBound, $1.termIndex)
            }
        }
        return HistoryGrade(
            baseQuality: baseQuality,
            quality: quality,
            isWordLevel: baseQuality >= wordLevelThreshold - 1e-9,
            occurrences: occurrences
        )
    }

    /// Highlight ranges (UTF-16, for `NSAttributedString`) of every credited term occurrence in
    /// `displayText`, sorted and with overlapping or touching ranges merged. Unlike `grade`, a
    /// term that is missing does not suppress the others.
    static func highlightRanges(in displayText: String, query: HistoryQuery, mode: BoundaryMode = .text) -> [NSRange] {
        guard !query.terms.isEmpty, !displayText.isEmpty else {
            return []
        }
        let folded = AgentHistorySearchText.normalizeWithMap(displayText)
        let occurrences = folded.utf8.withUnsafeBufferPointer {
            creditedOccurrences(normalizedUTF8: $0, terms: query.terms, mode: mode)
        }
        return highlightRanges(for: occurrences, in: folded)
    }

    /// Every credited occurrence of every term, sorted by position (then term index). Unlike
    /// `grade`, a term that is missing does not suppress the others.
    static func creditedOccurrences(
        normalizedUTF8 text: UnsafeBufferPointer<UInt8>,
        terms: [HistoryQueryTerm],
        mode: BoundaryMode = .text
    ) -> [HistoryTermOccurrence] {
        guard !text.isEmpty else {
            return []
        }
        var occurrences: [HistoryTermOccurrence] = []
        for (index, term) in terms.enumerated() {
            forEachCreditedOccurrence(of: PreparedTerm(term), in: text, mode: mode) { range, matchClass in
                occurrences.append(HistoryTermOccurrence(termIndex: index, bytes: range, matchClass: matchClass))
                return true
            }
        }
        occurrences.sort {
            ($0.bytes.lowerBound, $0.termIndex) < ($1.bytes.lowerBound, $1.termIndex)
        }
        return occurrences
    }

    /// Maps occurrences found in `folded.utf8` back to UTF-16 ranges of the text `folded` was
    /// built from, sorted and coalesced.
    static func highlightRanges(for occurrences: [HistoryTermOccurrence], in folded: AgentHistoryNormalizedText) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(occurrences.count)
        for occurrence in occurrences {
            let mapped = folded.sourceRange(forBytes: occurrence.bytes)
            if mapped.length > 0 {
                ranges.append(mapped)
            }
        }
        return coalesce(ranges)
    }

    // MARK: - Occurrences

    private struct PreparedTerm {
        let bytes: [UInt8]
        let scalarCount: Int
        let startsWithWordScalar: Bool
        let endsWithWordScalar: Bool

        init(_ term: HistoryQueryTerm) {
            self.init(bytes: term.utf8, scalars: term.text.unicodeScalars)
        }

        init(text: String) {
            self.init(bytes: Array(text.utf8), scalars: text.unicodeScalars)
        }

        private init(bytes: [UInt8], scalars: String.UnicodeScalarView) {
            self.bytes = bytes
            self.scalarCount = scalars.count
            self.startsWithWordScalar = scalars.first.map(HistoryMatcher.isWordScalar) ?? false
            self.endsWithWordScalar = scalars.last.map(HistoryMatcher.isWordScalar) ?? false
        }
    }

    /// Calls `body` for each credited occurrence, left to right (overlaps included). `body`
    /// returns false to stop.
    private static func forEachCreditedOccurrence(
        of term: PreparedTerm,
        in text: UnsafeBufferPointer<UInt8>,
        mode: BoundaryMode,
        _ body: (Range<Int>, HistoryMatchClass) -> Bool
    ) {
        guard !term.bytes.isEmpty, term.bytes.count <= text.count, let base = text.baseAddress else {
            return
        }
        let count = text.count
        term.bytes.withUnsafeBufferPointer { needle in
            guard let needleBase = needle.baseAddress else {
                return
            }
            var from = 0
            while from <= count - needle.count {
                guard let hit = memmem(base + from, count - from, needleBase, needle.count) else {
                    return
                }
                let start = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                let range = start..<(start + needle.count)
                let matchClass = classify(range, of: term, in: text, mode: mode)
                if matchClass != .none, !body(range, matchClass) {
                    return
                }
                from = start + 1
            }
        }
    }

    private static func classify(
        _ range: Range<Int>,
        of term: PreparedTerm,
        in text: UnsafeBufferPointer<UInt8>,
        mode: BoundaryMode
    ) -> HistoryMatchClass {
        let leftBoundary = !term.startsWithWordScalar
            || range.lowerBound == 0
            || !(scalar(before: range.lowerBound, in: text).map(isWordScalar) ?? false)
        let rightBoundary = !term.endsWithWordScalar
            || range.upperBound >= text.count
            || !(scalar(at: range.upperBound, in: text).map(isWordScalar) ?? false)

        if leftBoundary {
            return rightBoundary ? .word : .prefix
        }
        guard term.scalarCount >= minimumMidWordScalars, !isInsideHexToken(range, in: text) else {
            return .none
        }
        return .midWord
    }

    // MARK: - Word characters

    /// A letter or digit that is not CJK.
    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        if AgentHistorySearchText.isCJK(scalar) {
            return false
        }
        let properties = scalar.properties
        if properties.isAlphabetic {
            return true
        }
        switch properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func scalar(at index: Int, in text: UnsafeBufferPointer<UInt8>) -> Unicode.Scalar? {
        let lead = text[index]
        if lead < 0x80 {
            return Unicode.Scalar(lead)
        }
        let length: Int
        let mask: UInt8
        switch lead {
        case 0xC0...0xDF: (length, mask) = (2, 0x1F)
        case 0xE0...0xEF: (length, mask) = (3, 0x0F)
        case 0xF0...0xF7: (length, mask) = (4, 0x07)
        default: return nil
        }
        guard index + length <= text.count else {
            return nil
        }
        var value = UInt32(lead & mask)
        for offset in 1..<length {
            value = (value << 6) | UInt32(text[index + offset] & 0x3F)
        }
        return Unicode.Scalar(value)
    }

    private static func scalar(before index: Int, in text: UnsafeBufferPointer<UInt8>) -> Unicode.Scalar? {
        var start = index - 1
        while start > 0, index - start < 4, text[start] & 0xC0 == 0x80 {
            start -= 1
        }
        guard start >= 0 else {
            return nil
        }
        return scalar(at: start, in: text)
    }

    // MARK: - Hex guard

    /// How far the guard walks out of an occurrence looking for the enclosing token; enough for
    /// a SHA-256 or a UUID on either side.
    private static let hexRunScanLimit = 128

    private static func isRunByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte) || byte == UInt8(ascii: "-")
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// True when the occurrence lies inside a hex segment of seven or more digits, or inside an
    /// 8-4-4-4-12 UUID, within its enclosing `[0-9a-z-]` run.
    private static func isInsideHexToken(_ range: Range<Int>, in text: UnsafeBufferPointer<UInt8>) -> Bool {
        for index in range where !isRunByte(text[index]) {
            return false
        }
        var lower = range.lowerBound
        while lower > 0, range.lowerBound - lower < hexRunScanLimit, isRunByte(text[lower - 1]) {
            lower -= 1
        }
        var upper = range.upperBound
        while upper < text.count, upper - range.upperBound < hexRunScanLimit, isRunByte(text[upper]) {
            upper += 1
        }

        var segments: [Range<Int>] = []
        var segmentStart = lower
        for index in lower..<upper where text[index] == UInt8(ascii: "-") {
            segments.append(segmentStart..<index)
            segmentStart = index + 1
        }
        segments.append(segmentStart..<upper)

        func isHex(_ segment: Range<Int>) -> Bool {
            !segment.isEmpty && segment.allSatisfy { isHexByte(text[$0]) }
        }

        for segment in segments
        where segment.lowerBound <= range.lowerBound && range.upperBound <= segment.upperBound {
            if segment.count >= 7, isHex(segment) {
                return true
            }
        }

        let uuidShape = [8, 4, 4, 4, 12]
        if segments.count >= uuidShape.count {
            for first in 0...(segments.count - uuidShape.count) {
                let group = segments[first..<(first + uuidShape.count)]
                guard zip(group, uuidShape).allSatisfy({ $0.count == $1 && isHex($0) }) else {
                    continue
                }
                let span = group.first!.lowerBound..<group.last!.upperBound
                if span.lowerBound <= range.lowerBound, range.upperBound <= span.upperBound {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Proximity

    /// True when some window of at most `limit` bytes holds an occurrence of every term.
    /// `rangesPerTerm` lists each term's occurrences in ascending position.
    private static func hasCoveringWindow(_ rangesPerTerm: [[Range<Int>]], within limit: Int) -> Bool {
        guard rangesPerTerm.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        // The window's leftmost occurrence belongs to some term; for each candidate left edge,
        // every other term's best partner is its first occurrence at or after that edge.
        for (termIndex, ranges) in rangesPerTerm.enumerated() {
            candidates: for left in ranges {
                var end = left.upperBound
                for (otherIndex, others) in rangesPerTerm.enumerated() where otherIndex != termIndex {
                    guard let partner = firstRange(in: others, startingAtOrAfter: left.lowerBound) else {
                        // No partner to the right of this edge, nor of any later edge.
                        break candidates
                    }
                    end = max(end, partner.upperBound)
                    if end - left.lowerBound > limit {
                        continue candidates
                    }
                }
                if end - left.lowerBound <= limit {
                    return true
                }
            }
        }
        return false
    }

    private static func firstRange(in ranges: [Range<Int>], startingAtOrAfter position: Int) -> Range<Int>? {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].lowerBound < position {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count ? ranges[low] : nil
    }

    // MARK: - Helpers

    private static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func withUTF8<Result>(_ string: String, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        if let result = string.utf8.withContiguousStorageIfAvailable(body) {
            return result
        }
        return Array(string.utf8).withUnsafeBufferPointer(body)
    }
}
