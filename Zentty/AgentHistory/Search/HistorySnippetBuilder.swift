import Foundation

/// A one-line excerpt of a message around its best match, with highlight ranges (UTF-16) on
/// `text`. `text` includes a leading and/or trailing `…` when the excerpt was cut on that side.
struct HistorySnippet: Equatable, Sendable {
    let text: String
    let highlights: [NSRange]
    let truncatedStart: Bool
    let truncatedEnd: Bool
}

/// Builds the result-row snippet for a content hit.
///
/// Rules:
/// - The display text is cleaned first: markdown markers stripped (`stripMarkdown`), then every
///   whitespace run (newlines included) collapsed to one space.
/// - The window covers the shortest span holding one credited occurrence of every term found
///   in the text, using word-level (word or prefix) occurrences for any term that has one.
/// - It starts `leadIn` characters before that span, snapped forward to just past whitespace
///   within 15 characters, and ends `maxLength` characters later (ellipses included), snapped
///   back to whitespace within 20 characters. When the window reaches the end of the text it
///   is moved back to fill `maxLength`.
/// - Highlights come from the same matcher on the cleaned text, clipped to the window.
/// - No match (or no terms): the first `maxLength` characters, no highlights.
/// - Only the first `scanLimit` characters are read, matching the content tier, which grades
///   at most the first 64 KB of `search_text`.
enum HistorySnippetBuilder {
    static let defaultMaxLength = 150
    static let defaultLeadIn = 40
    static let startSnapLimit = 15
    static let endSnapLimit = 20
    static let scanLimit = 65_536
    static let ellipsis: Character = "…"

    static func snippet(
        for text: String,
        query: HistoryQuery,
        maxLength: Int = defaultMaxLength,
        leadIn: Int = defaultLeadIn
    ) -> HistorySnippet {
        let maxLength = max(maxLength, 3)
        let leadIn = max(leadIn, 0)
        let scanned = text.prefix(scanLimit)
        let wasCut = scanned.endIndex < text.endIndex
        let cleaned = collapseWhitespace(stripMarkdown(String(scanned)))

        let characters = Array(cleaned)
        // UTF-16 offset of every character start, plus the end.
        var offsets: [Int] = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters {
            offsets.append(offsets[offsets.count - 1] + character.utf16.count)
        }

        var span: Range<Int>?
        var highlights: [NSRange] = []
        if !query.terms.isEmpty, !cleaned.isEmpty {
            let folded = AgentHistorySearchText.normalizeWithMap(cleaned)
            let occurrences = folded.utf8.withUnsafeBufferPointer {
                HistoryMatcher.creditedOccurrences(normalizedUTF8: $0, terms: query.terms)
            }
            if let bytes = shortestCoveringSpan(occurrences) {
                let utf16 = folded.sourceRange(forBytes: bytes)
                let lower = characterIndex(atOrBefore: utf16.location, offsets: offsets)
                let upper = max(characterIndex(atOrAfter: NSMaxRange(utf16), offsets: offsets), lower + 1)
                span = lower..<min(upper, characters.count)
                highlights = HistoryMatcher.highlightRanges(for: occurrences, in: folded)
            }
        }

        let chosen = window(
            in: characters,
            span: span,
            wasCut: wasCut,
            maxLength: maxLength,
            leadIn: leadIn
        )
        return assemble(
            characters: characters,
            offsets: offsets,
            window: chosen,
            highlights: span == nil ? [] : highlights
        )
    }

    // MARK: - Window

    private struct Window {
        let range: Range<Int>
        let truncatedStart: Bool
        let truncatedEnd: Bool
    }

    private static func window(
        in characters: [Character],
        span: Range<Int>?,
        wasCut: Bool,
        maxLength: Int,
        leadIn: Int
    ) -> Window {
        let count = characters.count
        if !wasCut, count <= maxLength {
            return Window(range: 0..<count, truncatedStart: false, truncatedEnd: false)
        }

        var start = 0
        if let span {
            // Shrink the lead-in so a long span still shows from its start.
            let lead = max(0, min(leadIn, maxLength - 2 - span.count))
            start = snapStartForward(max(0, span.lowerBound - lead), limit: span.lowerBound, in: characters)
            // Near the end of the text, move back to use the full width.
            if !wasCut, count - start < maxLength - 1 {
                start = snapStartForward(max(0, count - (maxLength - 1)), limit: span.lowerBound, in: characters)
            }
        }

        let truncatedStart = start > 0
        let budget = maxLength - (truncatedStart ? 1 : 0)
        if !wasCut, count - start <= budget {
            return Window(range: start..<count, truncatedStart: truncatedStart, truncatedEnd: false)
        }

        var end = min(count, start + budget - 1)
        if end < count, !characters[end].isWhitespace, end > start, !characters[end - 1].isWhitespace {
            // Mid-word cut: back up to whitespace, but not into the matched span.
            var floor = max(start, end - endSnapLimit)
            if let span, span.upperBound <= end {
                floor = max(floor, span.upperBound)
            }
            var index = end - 1
            while index > floor, !characters[index].isWhitespace {
                index -= 1
            }
            if index > start, characters[index].isWhitespace {
                end = index
            }
        }
        while end > start, characters[end - 1].isWhitespace {
            end -= 1
        }
        return Window(range: start..<end, truncatedStart: truncatedStart, truncatedEnd: true)
    }

    /// Moves `start` forward to just past whitespace within `startSnapLimit` characters (never
    /// past `limit`) when it would otherwise cut a word, then past any whitespace.
    private static func snapStartForward(_ start: Int, limit: Int, in characters: [Character]) -> Int {
        var start = start
        if start > 0, !characters[start - 1].isWhitespace {
            let bound = min(start + startSnapLimit, limit)
            var index = start
            while index < bound, !characters[index].isWhitespace {
                index += 1
            }
            if index < bound {
                start = index + 1
            }
        }
        while start < limit, characters[start].isWhitespace {
            start += 1
        }
        return start
    }

    /// The shortest byte span holding one occurrence of every term that occurs at all. A term
    /// with any word-level occurrence only contributes its word-level ones. Ties go to the
    /// earliest span. `occurrences` must be sorted by position.
    private static func shortestCoveringSpan(_ occurrences: [HistoryTermOccurrence]) -> Range<Int>? {
        guard !occurrences.isEmpty else {
            return nil
        }
        let wordLevelTerms = Set(occurrences.lazy.filter { $0.matchClass >= .prefix }.map(\.termIndex))
        let candidates = occurrences.filter {
            $0.matchClass >= .prefix || !wordLevelTerms.contains($0.termIndex)
        }
        let needed = Set(candidates.map(\.termIndex)).count

        var counts: [Int: Int] = [:]
        var covered = 0
        var left = 0
        var best: (left: Int, right: Int, length: Int)?
        for right in candidates.indices {
            let term = candidates[right].termIndex
            counts[term, default: 0] += 1
            if counts[term] == 1 {
                covered += 1
            }
            while covered == needed {
                let length = candidates[right].bytes.upperBound - candidates[left].bytes.lowerBound
                if best == nil || length < best!.length {
                    best = (left, right, length)
                }
                let leftTerm = candidates[left].termIndex
                counts[leftTerm]! -= 1
                if counts[leftTerm] == 0 {
                    covered -= 1
                }
                left += 1
            }
        }
        guard let best else {
            return nil
        }
        let covering = candidates[best.left...best.right]
        let upper = covering.map(\.bytes.upperBound).max() ?? candidates[best.right].bytes.upperBound
        return candidates[best.left].bytes.lowerBound..<upper
    }

    // MARK: - Assembly

    private static func assemble(
        characters: [Character],
        offsets: [Int],
        window: Window,
        highlights: [NSRange]
    ) -> HistorySnippet {
        var text = window.truncatedStart ? String(ellipsis) : ""
        text.append(contentsOf: characters[window.range])
        if window.truncatedEnd {
            text.append(ellipsis)
        }

        let lower = offsets[window.range.lowerBound]
        let upper = offsets[window.range.upperBound]
        let shift = (window.truncatedStart ? String(ellipsis).utf16.count : 0) - lower
        var clipped: [NSRange] = []
        for range in highlights {
            let start = max(range.location, lower)
            let end = min(NSMaxRange(range), upper)
            if start < end {
                clipped.append(NSRange(location: start + shift, length: end - start))
            }
        }
        return HistorySnippet(
            text: text,
            highlights: clipped,
            truncatedStart: window.truncatedStart,
            truncatedEnd: window.truncatedEnd
        )
    }

    private static func characterIndex(atOrBefore utf16Offset: Int, offsets: [Int]) -> Int {
        // Last index whose offset is <= utf16Offset.
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= utf16Offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    private static func characterIndex(atOrAfter utf16Offset: Int, offsets: [Int]) -> Int {
        // First index whose offset is >= utf16Offset.
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] < utf16Offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Cleanup

    /// Collapses every whitespace run (newlines included) to one space and trims both ends.
    static func collapseWhitespace(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        // Non-whitespace runs are copied as slices rather than character by character; the
        // characters (and so the result) are the same.
        var runStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if isWhitespace(at: index, in: text) {
                if let start = runStart {
                    output.append(contentsOf: text[start..<index])
                    runStart = nil
                }
                pendingSpace = !output.isEmpty
            } else if runStart == nil {
                if pendingSpace {
                    output.append(" ")
                    pendingSpace = false
                }
                runStart = index
            }
            index = next
        }
        if let start = runStart {
            output.append(contentsOf: text[start...])
        }
        return output
    }

    /// `text[index].isWhitespace` (which tests the character's first scalar), answered from the
    /// first byte when it is ASCII: tab, line feed, vertical tab, form feed, carriage return or
    /// space.
    private static func isWhitespace(at index: String.Index, in text: String) -> Bool {
        let byte = text.utf8[index]
        if byte < 0x80 {
            return byte == 0x20 || (0x09...0x0D).contains(byte)
        }
        return text[index].isWhitespace
    }

    /// Removes markdown markup and keeps the text, line by line (leading indentation outside
    /// fences is dropped):
    /// - fence lines (```` ``` ```` / `~~~`) and thematic breaks (`---`, `***`, `___`) are
    ///   dropped; lines inside a fence are kept verbatim;
    /// - leading `>` quotes, `#` headings and `-`/`*`/`+` bullets lose their marker;
    /// - code spans lose their backticks and keep their content literally;
    /// - `[text](url)` and `![alt](url)` become `text` / `alt`;
    /// - paired `*`, `**`, `***` and `~~` emphasis runs are removed. Unpaired runs (`2 * 3`,
    ///   `a*b`, globs) stay. Underscores are left alone so identifiers like `snake_case` and
    ///   `__init__` survive.
    static func stripMarkdown(_ text: String) -> String {
        var lines: [String] = []
        var fence: Substring?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if trimmed.hasPrefix(open) {
                    fence = nil
                } else {
                    lines.append(String(line))
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                continue
            }
            if isThematicBreak(trimmed) {
                continue
            }
            lines.append(stripInline(stripBlockMarkers(trimmed)))
        }
        return lines.joined(separator: "\n")
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        guard let marker = line.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        var markers = 0
        for character in line {
            if character == marker {
                markers += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return markers >= 3
    }

    private static func stripBlockMarkers(_ line: Substring) -> Substring {
        var rest = line
        // Block quotes, possibly nested.
        while rest.first == ">" {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        // ATX heading: 1–6 `#` followed by a space or the end of the line.
        let hashes = rest.prefix { $0 == "#" }
        if (1...6).contains(hashes.count) {
            let after = rest.dropFirst(hashes.count)
            if after.isEmpty || after.first == " " || after.first == "\t" {
                return after.drop { $0 == " " || $0 == "\t" }
            }
        }
        // Bullet.
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            if after.first == " " || after.first == "\t" {
                return after.drop { $0 == " " || $0 == "\t" }
            }
        }
        return rest
    }

    private static func stripInline(_ line: Substring) -> String {
        // Without a backtick, `[`, `*` or `~` nothing below can match: keep the line as is.
        // (These are ASCII, so their bytes never occur inside a multi-byte character.)
        if !line.utf8.contains(where: { $0 == UInt8(ascii: "`") || $0 == UInt8(ascii: "[")
            || $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "~") }) {
            return String(line)
        }
        let characters = Array(line)
        let count = characters.count
        guard count > 0 else {
            return ""
        }
        var removed = [Bool](repeating: false, count: count)
        var literal = [Bool](repeating: false, count: count)

        // Code spans: a backtick run closed by a run of the same length.
        var index = 0
        while index < count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            let openLength = runLength(of: "`", at: index, in: characters)
            var search = index + openLength
            var closeStart: Int?
            while search < count {
                if characters[search] == "`" {
                    let length = runLength(of: "`", at: search, in: characters)
                    if length == openLength {
                        closeStart = search
                        break
                    }
                    search += length
                } else {
                    search += 1
                }
            }
            guard let closeStart else {
                index += openLength
                continue
            }
            for marker in index..<(index + openLength) {
                removed[marker] = true
            }
            for content in (index + openLength)..<closeStart {
                literal[content] = true
            }
            for marker in closeStart..<(closeStart + openLength) {
                removed[marker] = true
            }
            index = closeStart + openLength
        }

        // Links and images: `[text](url)` / `![alt](url)`.
        index = 0
        while index < count {
            guard characters[index] == "[", !literal[index], !removed[index] else {
                index += 1
                continue
            }
            var close = index + 1
            while close < count, characters[close] != "]", characters[close] != "[" {
                close += 1
            }
            guard close + 1 < count, characters[close] == "]", characters[close + 1] == "(" else {
                index += 1
                continue
            }
            var urlEnd = close + 2
            while urlEnd < count, characters[urlEnd] != ")", !characters[urlEnd].isWhitespace {
                urlEnd += 1
            }
            guard urlEnd < count, characters[urlEnd] == ")" else {
                index += 1
                continue
            }
            if index > 0, characters[index - 1] == "!", !literal[index - 1] {
                removed[index - 1] = true
            }
            removed[index] = true
            for marker in close...urlEnd {
                removed[marker] = true
            }
            index = urlEnd + 1
        }

        // Emphasis: pair `*` runs (and `~~`) of equal length.
        struct Delimiter {
            let character: Character
            let start: Int
            let length: Int
        }
        var openers: [Delimiter] = []
        index = 0
        while index < count {
            let character = characters[index]
            guard character == "*" || character == "~", !literal[index], !removed[index] else {
                index += 1
                continue
            }
            let length = runLength(of: character, at: index, in: characters)
            defer { index += length }
            if character == "~", length != 2 {
                continue
            }
            if character == "*", length > 3 {
                continue
            }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + length < count ? characters[index + length] : nil
            let canOpen = (next.map { !$0.isWhitespace } ?? false)
                && (previous.map { $0.isWhitespace || isPunctuation($0) } ?? true)
            let canClose = (previous.map { !$0.isWhitespace } ?? false)
                && (next.map { $0.isWhitespace || isPunctuation($0) } ?? true)

            if canClose,
               let match = openers.lastIndex(where: { $0.character == character && $0.length == length }) {
                let opener = openers[match]
                for marker in opener.start..<(opener.start + opener.length) {
                    removed[marker] = true
                }
                for marker in index..<(index + length) {
                    removed[marker] = true
                }
                openers.removeSubrange(match...)
                continue
            }
            if canOpen {
                openers.append(Delimiter(character: character, start: index, length: length))
            }
        }

        var output = ""
        output.reserveCapacity(count)
        for position in 0..<count where !removed[position] {
            output.append(characters[position])
        }
        return output
    }

    private static func runLength(of character: Character, at start: Int, in characters: [Character]) -> Int {
        var end = start
        while end < characters.count, characters[end] == character {
            end += 1
        }
        return end - start
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character.isSymbol
    }
}
