import Darwin
import Foundation

/// Cheap reads from one JSONL line without a full JSON decode.
///
/// `topLevel` walks only the outer object: values of keys nobody asked for are skipped with a
/// string-aware bracket matcher, and the walk stops as soon as every requested key was seen.
/// Claude `assistant` records put a large `message` before `type`, so the walk cannot assume
/// `type` sits in the first bytes; a line that starts with `{"type":"` still answers at once.
///
/// The sniffer is not a validator: it returns nil for structural damage it walks over, and
/// ignores anything after the point where it could stop.
enum JSONLineSniffer {
    enum PathComponent: Equatable {
        case key(String)
        case index(Int)
    }

    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case number
        case null
        case object
        case array
    }

    struct TopLevel: Equatable {
        /// Requested keys whose value is a JSON string.
        var strings: [String: String] = [:]
        /// Requested flag keys whose value is the literal `true`.
        var trueFlags: Set<String> = []
        /// Requested presence keys with a non-null value.
        var presentKeys: Set<String> = []
    }

    static func topLevel(
        in line: UnsafeRawBufferPointer,
        stringKeys: [String],
        flagKeys: [String],
        presenceKeys: [String]
    ) -> TopLevel? {
        var result = TopLevel()
        let wanted = Set(stringKeys).union(flagKeys).union(presenceKeys)
        if stringKeys == ["type"], wanted.count == 1, let fast = fastType(in: line) {
            result.strings["type"] = fast
            return result
        }
        let stringSet = Set(stringKeys)
        let flagSet = Set(flagKeys)
        let presenceSet = Set(presenceKeys)
        var seen: Set<String> = []

        var scanner = ByteScanner(line)
        guard scanner.skipWhitespaceAndTake(UInt8(ascii: "{")) else {
            return nil
        }
        scanner.skipWhitespace()
        if scanner.take(UInt8(ascii: "}")) {
            return result
        }
        while true {
            scanner.skipWhitespace()
            guard let key = scanner.readString(), scanner.skipWhitespaceAndTake(UInt8(ascii: ":")) else {
                return nil
            }
            scanner.skipWhitespace()
            guard wanted.contains(key) else {
                guard scanner.skipValue() else {
                    return nil
                }
                if !scanner.finishMember() {
                    return nil
                }
                if scanner.closedObject {
                    return result
                }
                continue
            }

            seen.insert(key)
            guard let first = scanner.peek() else {
                return nil
            }
            if first == UInt8(ascii: "\""), stringSet.contains(key) {
                guard let value = scanner.readString() else {
                    return nil
                }
                result.strings[key] = value
                if presenceSet.contains(key) {
                    result.presentKeys.insert(key)
                }
            } else {
                let kind = scanner.peekKind()
                guard scanner.skipValue() else {
                    return nil
                }
                if kind == .bool(true), flagSet.contains(key) {
                    result.trueFlags.insert(key)
                }
                if kind != .null, presenceSet.contains(key) {
                    result.presentKeys.insert(key)
                }
            }
            if seen.count == wanted.count {
                return result
            }
            if !scanner.finishMember() {
                return nil
            }
            if scanner.closedObject {
                return result
            }
        }
    }

    /// Follows `path` from the root value. nil when a step is missing, has the wrong container
    /// type, or the walk meets malformed JSON. Objects and arrays at the end are not validated.
    static func value(at path: [PathComponent], in line: UnsafeRawBufferPointer) -> Value? {
        var scanner = ByteScanner(line)
        scanner.skipWhitespace()
        for component in path {
            switch component {
            case .key(let wantedKey):
                guard scanner.seekKey(wantedKey) else {
                    return nil
                }
            case .index(let wantedIndex):
                guard scanner.seekIndex(wantedIndex) else {
                    return nil
                }
            }
        }
        return scanner.readTerminalValue()
    }

    /// Byte substring search (`memmem`). An empty needle always matches.
    static func contains(_ needle: String, in line: UnsafeRawBufferPointer) -> Bool {
        var needle = needle
        return needle.withUTF8 { needleBytes in
            guard needleBytes.count > 0 else {
                return true
            }
            guard let base = line.baseAddress, line.count >= needleBytes.count else {
                return false
            }
            return memmem(base, line.count, needleBytes.baseAddress!, needleBytes.count) != nil
        }
    }

    // MARK: - Fast path

    private static let typePrefix = Array(#"{"type":""#.utf8)

    /// `{"type":"<plain string>"` at the very start of the line.
    private static func fastType(in line: UnsafeRawBufferPointer) -> String? {
        guard line.count > typePrefix.count, let base = line.baseAddress else {
            return nil
        }
        guard memcmp(base, typePrefix, typePrefix.count) == 0 else {
            return nil
        }
        var scanner = ByteScanner(line)
        scanner.index = typePrefix.count - 1
        return scanner.readString()
    }
}

/// Index-based cursor over the line bytes. All reads are bounds-checked.
private struct ByteScanner {
    let bytes: UnsafeRawBufferPointer
    var index = 0
    /// Set by `finishMember` when it consumed the object's closing brace.
    var closedObject = false

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard peek() == byte else {
            return false
        }
        index += 1
        return true
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    mutating func skipWhitespaceAndTake(_ byte: UInt8) -> Bool {
        skipWhitespace()
        return take(byte)
    }

    /// After a member value: `,` continues, `}` closes (sets `closedObject`). false otherwise.
    mutating func finishMember() -> Bool {
        skipWhitespace()
        if take(UInt8(ascii: ",")) {
            return true
        }
        if take(UInt8(ascii: "}")) {
            closedObject = true
            return true
        }
        return false
    }

    /// Kind of the value at `index` from its first byte (literals checked in full).
    func peekKind() -> JSONLineSniffer.Value? {
        guard let first = peek() else {
            return nil
        }
        switch first {
        case UInt8(ascii: "\""): return .string("")
        case UInt8(ascii: "{"): return .object
        case UInt8(ascii: "["): return .array
        case UInt8(ascii: "t"): return matches("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return matches("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return matches("null") ? .null : nil
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number
        default: return nil
        }
    }

    private func matches(_ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else {
            return false
        }
        let pointer = literal.utf8Start
        for offset in 0..<count where bytes[index + offset] != pointer[offset] {
            return false
        }
        return true
    }

    // MARK: Strings

    /// Reads a string starting at the opening quote and decodes its escapes.
    mutating func readString() -> String? {
        guard take(UInt8(ascii: "\"")) else {
            return nil
        }
        var decoded: [UInt8] = []
        var runStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                decoded.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[runStart..<index]))
                index += 1
                return String(decoding: decoded, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                decoded.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[runStart..<index]))
                index += 1
                guard decodeEscape(into: &decoded) else {
                    return nil
                }
                runStart = index
                continue
            }
            index += 1
        }
        return nil
    }

    /// `index` sits just after the backslash.
    private mutating func decodeEscape(into decoded: inout [UInt8]) -> Bool {
        guard let byte = peek() else {
            return false
        }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(byte)
        case UInt8(ascii: "b"): decoded.append(0x08)
        case UInt8(ascii: "f"): decoded.append(0x0C)
        case UInt8(ascii: "n"): decoded.append(0x0A)
        case UInt8(ascii: "r"): decoded.append(0x0D)
        case UInt8(ascii: "t"): decoded.append(0x09)
        case UInt8(ascii: "u"):
            guard let unit = readHex4() else {
                return false
            }
            var scalar: Unicode.Scalar?
            if (0xD800...0xDBFF).contains(unit) {
                let save = index
                if take(UInt8(ascii: "\\")), take(UInt8(ascii: "u")), let low = readHex4(), (0xDC00...0xDFFF).contains(low) {
                    scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                } else {
                    index = save
                }
            } else if !(0xDC00...0xDFFF).contains(unit) {
                scalar = Unicode.Scalar(UInt32(unit))
            }
            decoded.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
        default:
            return false
        }
        return true
    }

    private mutating func readHex4() -> UInt16? {
        guard index + 4 <= bytes.count else {
            return nil
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    /// Skips a string starting at the opening quote, validating escapes, without decoding.
    mutating func skipString() -> Bool {
        guard take(UInt8(ascii: "\"")) else {
            return false
        }
        while index < bytes.count {
            let remaining = bytes.count - index
            let base = bytes.baseAddress! + index
            // Jump to the next quote or backslash.
            var next = index + remaining
            if let quote = memchr(base, Int32(UInt8(ascii: "\"")), remaining) {
                next = index + (UnsafeRawPointer(quote) - UnsafeRawPointer(base))
            }
            if let slash = memchr(base, Int32(UInt8(ascii: "\\")), next - index) {
                index += UnsafeRawPointer(slash) - UnsafeRawPointer(base) + 1
                guard skipEscape() else {
                    return false
                }
                continue
            }
            guard next < bytes.count else {
                index = bytes.count
                return false
            }
            index = next + 1
            return true
        }
        return false
    }

    /// `index` sits just after the backslash.
    private mutating func skipEscape() -> Bool {
        guard let byte = peek() else {
            return false
        }
        index += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
             UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
            return true
        case UInt8(ascii: "u"):
            return readHex4() != nil
        default:
            return false
        }
    }

    // MARK: Values

    /// Skips one value at `index`. Containers are matched with a bracket stack (string-aware),
    /// so mismatched or unterminated brackets fail; separators inside containers are not checked.
    mutating func skipValue() -> Bool {
        guard let first = peek() else {
            return false
        }
        switch first {
        case UInt8(ascii: "\""):
            return skipString()
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            return skipContainer()
        case UInt8(ascii: "t"):
            return skipLiteral("true")
        case UInt8(ascii: "f"):
            return skipLiteral("false")
        case UInt8(ascii: "n"):
            return skipLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return skipNumber()
        default:
            return false
        }
    }

    private mutating func skipLiteral(_ literal: StaticString) -> Bool {
        guard matches(literal) else {
            return false
        }
        index += literal.utf8CodeUnitCount
        return true
    }

    private mutating func skipNumber() -> Bool {
        let start = index
        while let byte = peek() {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                index += 1
            default:
                return index > start
            }
        }
        return index > start
    }

    private mutating func skipContainer() -> Bool {
        var stack: [UInt8] = []
        while let byte = peek() {
            switch byte {
            case UInt8(ascii: "\""):
                guard skipString() else {
                    return false
                }
                continue
            case UInt8(ascii: "{"):
                stack.append(UInt8(ascii: "}"))
            case UInt8(ascii: "["):
                stack.append(UInt8(ascii: "]"))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard stack.popLast() == byte else {
                    return false
                }
                if stack.isEmpty {
                    index += 1
                    return true
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    // MARK: Path navigation

    /// At an object: moves `index` to the value of `key` (whitespace skipped).
    mutating func seekKey(_ key: String) -> Bool {
        guard take(UInt8(ascii: "{")) else {
            return false
        }
        skipWhitespace()
        if take(UInt8(ascii: "}")) {
            return false
        }
        closedObject = false
        while true {
            skipWhitespace()
            guard let candidate = readString(), skipWhitespaceAndTake(UInt8(ascii: ":")) else {
                return false
            }
            skipWhitespace()
            if candidate == key {
                return true
            }
            guard skipValue(), finishMember(), !closedObject else {
                return false
            }
        }
    }

    /// At an array: moves `index` to element `position` (whitespace skipped).
    mutating func seekIndex(_ position: Int) -> Bool {
        guard position >= 0, take(UInt8(ascii: "[")) else {
            return false
        }
        skipWhitespace()
        if take(UInt8(ascii: "]")) {
            return false
        }
        var current = 0
        while true {
            skipWhitespace()
            if current == position {
                return true
            }
            guard skipValue() else {
                return false
            }
            skipWhitespace()
            guard take(UInt8(ascii: ",")) else {
                return false
            }
            current += 1
        }
    }

    mutating func readTerminalValue() -> JSONLineSniffer.Value? {
        guard let kind = peekKind() else {
            return nil
        }
        switch kind {
        case .string:
            return readString().map { .string($0) }
        case .number:
            return skipNumber() ? .number : nil
        default:
            return kind
        }
    }
}
