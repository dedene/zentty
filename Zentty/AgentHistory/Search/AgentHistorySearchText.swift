import Foundation

/// The one text fold shared by ingest (`messages.search_text`, artifact and summary keys) and
/// queries. Nothing else in Agent History may lowercase, fold diacritics or straighten quotes:
/// a second fold drifts from this one and silently loses matches.
///
/// Rules:
/// - ASCII fast path (every UTF-8 byte < 0x80): lowercase `A`–`Z`, map `\t \n \r \f \v` to a
///   space, collapse space runs. No Foundation calls.
/// - Otherwise, per `Character` of the input: NFC; whitespace → one collapsed space;
///   `‘ ’ ‚ ‛ ′` → `'` and `“ ” „ ‟ ″ « »` → `"`; else `lowercased()`, width folding, and
///   diacritic folding only when the first scalar is Latin, Greek or Cyrillic (< U+0530 or
///   U+1E00–U+1FFF), so kana dakuten (`が`) and Hangul stay intact.
/// - Leading and trailing whitespace is dropped.
///
/// `normalize(x) == normalizeWithMap(x).text` for every input: both run the same loop.
enum AgentHistorySearchText {
    static func normalize(_ text: String) -> String {
        var builder = Builder(recordsMap: false)
        builder.run(text)
        return String(decoding: builder.bytes, as: UTF8.self)
    }

    /// Same fold, plus the source UTF-16 bounds of every output UTF-8 byte (for highlighting
    /// matches found in the folded text back on the display text).
    static func normalizeWithMap(_ text: String) -> AgentHistoryNormalizedText {
        var builder = Builder(recordsMap: true)
        builder.run(text)
        return AgentHistoryNormalizedText(
            text: String(decoding: builder.bytes, as: UTF8.self),
            utf8: builder.bytes,
            sourceStart: builder.sourceStart,
            sourceEnd: builder.sourceEnd
        )
    }

    /// Han ideographs, kana, Hangul and Bopomofo: scripts written without spaces between words.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2FDF,   // CJK radicals, Kangxi radicals
             0x3005...0x3007,   // 々 〆 〇
             0x3021...0x3029,   // Hangzhou numerals
             0x3031...0x3035,   // kana repeat marks
             0x303B...0x303C,
             0x3041...0x309F,   // Hiragana (incl. voiced sound marks)
             0x30A0...0x30FF,   // Katakana
             0x3100...0x312F,   // Bopomofo
             0x3130...0x318F,   // Hangul Compatibility Jamo
             0x31A0...0x31BF,   // Bopomofo Extended
             0x31F0...0x31FF,   // Katakana Phonetic Extensions
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7AF,   // Hangul Syllables
             0xD7B0...0xD7FF,   // Hangul Jamo Extended-B
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF66...0xFF9F,   // Halfwidth Katakana
             0xFFA0...0xFFDC,   // Halfwidth Hangul
             0x1B000...0x1B16F, // Kana Supplement / Extended-A
             0x20000...0x323AF: // CJK Extensions B–H, Compatibility Supplement
            return true
        default:
            return false
        }
    }

    /// True when `text` has at least one letter, digit or CJK character, i.e. something a
    /// full-text tokenizer indexes rather than pure punctuation, symbols or whitespace.
    static func containsWordCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isWordScalar)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        if isCJK(scalar) {
            return true
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

    // MARK: - Fold

    fileprivate static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        // space, \t, \n, \v, \f, \r
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    fileprivate static func straightQuote(for scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032:
            return UInt8(ascii: "'")
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x00AB, 0x00BB:
            return UInt8(ascii: "\"")
        default:
            return nil
        }
    }

    /// Fold of one NFC grapheme that is not whitespace and not a quote.
    fileprivate static func fold(_ grapheme: String) -> String {
        var folded = grapheme.lowercased().folding(options: .widthInsensitive, locale: nil)
        if let first = folded.unicodeScalars.first,
           first.value < 0x0530 || (0x1E00...0x1FFF).contains(first.value) {
            folded = folded.folding(options: .diacriticInsensitive, locale: nil)
        }
        // Width folding can leave a decomposed result (halfwidth `ｶﾞ` → `カ` + U+3099).
        if folded.unicodeScalars.count > 1 {
            folded = folded.precomposedStringWithCanonicalMapping
        }
        return folded
    }

    private struct Builder {
        let recordsMap: Bool
        var bytes: [UInt8] = []
        var sourceStart: [Int32] = []
        var sourceEnd: [Int32] = []
        /// Start of the pending whitespace run, or nil. A space is written only once
        /// non-space output follows, so leading and trailing runs vanish.
        private var pendingSpaceStart: Int32?
        private var pendingSpaceEnd: Int32 = 0
        private var cache: [Character: [UInt8]] = [:]

        init(recordsMap: Bool) {
            self.recordsMap = recordsMap
        }

        mutating func run(_ text: String) {
            let isASCII = text.utf8.allSatisfy { $0 < 0x80 }
            bytes.reserveCapacity(text.utf8.count)
            if recordsMap {
                sourceStart.reserveCapacity(text.utf8.count)
                sourceEnd.reserveCapacity(text.utf8.count)
            }
            if isASCII {
                runASCII(text)
            } else {
                runUnicode(text)
            }
        }

        private mutating func runASCII(_ text: String) {
            // For ASCII, UTF-8 offset == UTF-16 offset.
            var offset: Int32 = 0
            for byte in text.utf8 {
                handleASCII(byte, start: offset, end: offset + 1)
                offset += 1
            }
        }

        private mutating func runUnicode(_ text: String) {
            var offset: Int32 = 0
            for character in text {
                let start = offset
                let end = offset + Int32(character.utf16.count)
                offset = end

                // `asciiValue` is also non-nil for "\r\n" (as 0x0A), which is whitespace.
                if let ascii = character.asciiValue {
                    handleASCII(ascii, start: start, end: end)
                    continue
                }
                if character.isWhitespace {
                    noteWhitespace(start: start, end: end)
                    continue
                }
                let scalars = character.unicodeScalars
                if scalars.count == 1, let quote = AgentHistorySearchText.straightQuote(for: scalars[scalars.startIndex]) {
                    emit([quote], start: start, end: end)
                    continue
                }
                let folded: [UInt8]
                if let cached = cache[character] {
                    folded = cached
                } else {
                    folded = Array(AgentHistorySearchText.fold(String(character).precomposedStringWithCanonicalMapping).utf8)
                    cache[character] = folded
                }
                if !folded.isEmpty {
                    emit(folded, start: start, end: end)
                }
            }
        }

        private mutating func handleASCII(_ byte: UInt8, start: Int32, end: Int32) {
            if AgentHistorySearchText.isASCIIWhitespace(byte) {
                noteWhitespace(start: start, end: end)
                return
            }
            let lowered = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            emit(CollectionOfOne(lowered), start: start, end: end)
        }

        private mutating func noteWhitespace(start: Int32, end: Int32) {
            guard !bytes.isEmpty else {
                return
            }
            if pendingSpaceStart == nil {
                pendingSpaceStart = start
            }
            pendingSpaceEnd = end
        }

        private mutating func emit<Bytes: Collection>(_ output: Bytes, start: Int32, end: Int32)
            where Bytes.Element == UInt8 {
            if let spaceStart = pendingSpaceStart {
                bytes.append(0x20)
                if recordsMap {
                    sourceStart.append(spaceStart)
                    sourceEnd.append(pendingSpaceEnd)
                }
                pendingSpaceStart = nil
            }
            bytes.append(contentsOf: output)
            if recordsMap {
                for _ in 0..<output.count {
                    sourceStart.append(start)
                    sourceEnd.append(end)
                }
            }
        }
    }
}

/// Folded text plus, for every UTF-8 byte of it, the UTF-16 range of the source grapheme
/// (or whitespace run) that produced it.
struct AgentHistoryNormalizedText: Sendable {
    let text: String
    let utf8: [UInt8]
    let sourceStart: [Int32]
    let sourceEnd: [Int32]

    /// Source UTF-16 range covering output bytes `r`, widened to whole source graphemes.
    /// Out-of-range bounds are clamped; an empty `r` yields an empty range at its position.
    func sourceRange(forBytes r: Range<Int>) -> NSRange {
        let count = utf8.count
        let lower = min(max(r.lowerBound, 0), count)
        let upper = min(max(r.upperBound, lower), count)
        guard lower < upper else {
            let location: Int32
            if lower < count {
                location = sourceStart[lower]
            } else {
                location = sourceEnd.last ?? 0
            }
            return NSRange(location: Int(location), length: 0)
        }
        let start = Int(sourceStart[lower])
        let end = Int(sourceEnd[upper - 1])
        return NSRange(location: start, length: max(end - start, 0))
    }
}
