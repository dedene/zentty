import Foundation

extension ClaudeRetentionSettings {
    /// Sets `cleanupPeriodDays` by editing the JSON text, so every other byte (key order,
    /// indentation, spacing, escapes) survives. Replaces the value of every top-level
    /// occurrence of the key (duplicates included); nested objects and strings that merely
    /// contain the key are skipped. Without the key, it is inserted as the first member,
    /// matching the first member's indentation.
    ///
    /// Returns `nil` when the text isn't a well-formed top-level object as far as the scanner
    /// can tell. The caller verifies the result by parsing it and falls back to re-serializing.
    static func updatedJSONText(_ text: String, settingDays days: Int) -> String? {
        let bytes = Array(text.utf8)
        var scanner = TopLevelObjectScanner(bytes: bytes, key: key)
        guard let layout = scanner.scan() else {
            return nil
        }

        var result = bytes
        let value = Array(String(days).utf8)
        if !layout.valueSpans.isEmpty {
            for span in layout.valueSpans.reversed() {
                result.replaceSubrange(span, with: value)
            }
            return String(decoding: result, as: UTF8.self)
        }

        let member = "\"\(key)\": \(days)"
        guard let firstMember = layout.firstMemberStart else {
            result.replaceSubrange(layout.openBrace...layout.closeBrace, with: Array("{\n  \(member)\n}".utf8))
            return String(decoding: result, as: UTF8.self)
        }

        let gapStart = layout.openBrace + 1
        let gap = bytes[gapStart..<firstMember]
        let insertion: String
        if let newline = gap.lastIndex(of: UInt8(ascii: "\n")) {
            let lineBreak = newline > gapStart && bytes[newline - 1] == UInt8(ascii: "\r") ? "\r\n" : "\n"
            let indent = String(decoding: bytes[(newline + 1)..<firstMember], as: UTF8.self)
            insertion = "\(lineBreak)\(indent)\(member),"
        } else if gap.isEmpty {
            insertion = "\(member), "
        } else {
            insertion = " \(member),"
        }
        result.insert(contentsOf: Array(insertion.utf8), at: gapStart)
        return String(decoding: result, as: UTF8.self)
    }

    /// The raw text of the last top-level `cleanupPeriodDays` value, or `nil` when the key is
    /// absent at the top level or the scanner can't read the object.
    static func lastTopLevelValueText(in text: String) -> String? {
        let bytes = Array(text.utf8)
        var scanner = TopLevelObjectScanner(bytes: bytes, key: key)
        guard let span = scanner.scan()?.valueSpans.last else {
            return nil
        }
        return String(decoding: bytes[span], as: UTF8.self)
    }

    /// True when a `,` is followed (after whitespace) by `}` or `]` outside a string.
    /// `JSONSerialization` accepts that; strict JSON does not.
    static func containsTrailingComma(_ data: Data) -> Bool {
        var inString = false
        var escaped = false
        var lastSignificant: UInt8 = 0
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                    lastSignificant = byte
                }
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if lastSignificant == UInt8(ascii: ",") {
                    return true
                }
            default:
                break
            }
            lastSignificant = byte
        }
        return false
    }
}

/// A byte scanner over the top level of one JSON object. Depth-, string- and escape-aware;
/// it validates only the structure it needs and leaves full validation to `JSONSerialization`.
private struct TopLevelObjectScanner {
    struct Layout {
        var openBrace: Int
        var closeBrace: Int
        var firstMemberStart: Int?
        var valueSpans: [Range<Int>]
    }

    private let bytes: [UInt8]
    private let quotedKey: [UInt8]
    private let key: String
    private var index = 0

    init(bytes: [UInt8], key: String) {
        self.bytes = bytes
        self.key = key
        self.quotedKey = Array("\"\(key)\"".utf8)
    }

    mutating func scan() -> Layout? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        skipWhitespace()
        guard peek() == UInt8(ascii: "{") else {
            return nil
        }
        var layout = Layout(openBrace: index, closeBrace: index, firstMemberStart: nil, valueSpans: [])
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            layout.closeBrace = index
            return layout
        }
        layout.firstMemberStart = index

        while true {
            guard peek() == UInt8(ascii: "\"") else {
                return nil
            }
            let keyStart = index
            guard skipString() else {
                return nil
            }
            let isTarget = isTargetKey(keyStart..<index)
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else {
                return nil
            }
            index += 1
            skipWhitespace()
            let valueStart = index
            guard skipValue() else {
                return nil
            }
            if isTarget {
                layout.valueSpans.append(valueStart..<index)
            }
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
                skipWhitespace()
            case UInt8(ascii: "}"):
                layout.closeBrace = index
                return layout
            default:
                return nil
            }
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    /// At an opening quote: moves past the closing quote.
    private mutating func skipString() -> Bool {
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                index += 2
            case UInt8(ascii: "\""):
                index += 1
                return true
            default:
                index += 1
            }
        }
        return false
    }

    private mutating func skipValue() -> Bool {
        guard let first = peek() else {
            return false
        }
        switch first {
        case UInt8(ascii: "\""):
            return skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while let byte = peek() {
                switch byte {
                case UInt8(ascii: "\""):
                    guard skipString() else {
                        return false
                    }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                default:
                    break
                }
                index += 1
                if depth == 0 {
                    return true
                }
            }
            return false
        default:
            let start = index
            while let byte = peek(),
                  byte != UInt8(ascii: ","), byte != UInt8(ascii: "}"), byte != UInt8(ascii: "]"),
                  byte != 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D {
                index += 1
            }
            return index > start
        }
    }

    private func isTargetKey(_ range: Range<Int>) -> Bool {
        let literal = bytes[range]
        guard literal.contains(UInt8(ascii: "\\")) else {
            return literal.elementsEqual(quotedKey)
        }
        let decoded = try? JSONSerialization.jsonObject(with: Data(literal), options: [.fragmentsAllowed]) as? String
        return decoded == key
    }
}
