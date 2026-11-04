import Foundation

/// Commands inside a code-mode `exec` tool call (`custom_tool_call`, `name: "exec"`), the shape
/// current Codex uses for all shell work. The input is a JavaScript snippet that may run several
/// commands:
///
///     text(await tools.exec_command({cmd:"git status --short","max_output_tokens":6000}));
///     text(await tools.exec_command({cmd:`gh api 'repos/${repo}/pulls'`,yield_time_ms:1000}));
///
/// Only a literal `cmd` is read: a double- or single-quoted string (JSON/JS escapes decoded) or a
/// template literal (`${…}` kept as written). A `cmd` computed from an expression is skipped.
/// Patches have no `exec` form of their own (no `tools.apply_patch` call has been seen in exec
/// inputs); a patch applied through a command indexes as that command.
enum CodexExecInput {
    private static let callMarker = Array("exec_command(".utf8)

    static func commands(in input: String) -> [String] {
        let bytes = Array(input.utf8)
        var commands: [String] = []
        var index = 0
        while let start = find(callMarker, in: bytes, from: index) {
            var scanner = Scanner(bytes: bytes, position: start + callMarker.count)
            if let command = scanner.cmdArgument() {
                commands.append(command)
            }
            index = max(scanner.position, start + callMarker.count)
        }
        return commands
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count else {
            return nil
        }
        var index = start
        while index + needle.count <= haystack.count {
            if haystack[index] == needle[0], haystack[index ..< index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// A forgiving scanner over one call's argument object.
    private struct Scanner {
        let bytes: [UInt8]
        var position: Int

        private static let quote = UInt8(ascii: "\"")
        private static let apostrophe = UInt8(ascii: "'")
        private static let backtick = UInt8(ascii: "`")
        private static let backslash = UInt8(ascii: "\\")

        /// The literal `cmd` property of `({…})`, nil when absent or not a literal.
        mutating func cmdArgument() -> String? {
            skipWhitespace()
            guard consume(UInt8(ascii: "{")) else {
                return nil
            }
            while position < bytes.count {
                skipWhitespace()
                if consume(UInt8(ascii: "}")) {
                    return nil
                }
                guard let key = readKey() else {
                    return nil
                }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else {
                    return nil
                }
                skipWhitespace()
                if key == "cmd" {
                    return readStringLiteral()
                }
                skipValue()
                skipWhitespace()
                guard consume(UInt8(ascii: ",")) else {
                    return nil
                }
            }
            return nil
        }

        private mutating func readKey() -> String? {
            guard position < bytes.count else {
                return nil
            }
            if bytes[position] == Self.quote || bytes[position] == Self.apostrophe {
                return readStringLiteral()
            }
            let start = position
            while position < bytes.count, Self.isIdentifierByte(bytes[position]) {
                position += 1
            }
            return position > start ? String(decoding: bytes[start ..< position], as: UTF8.self) : nil
        }

        /// Skips one value up to the next top-level `,` or `}` (strings and nesting respected).
        private mutating func skipValue() {
            var depth = 0
            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case Self.quote, Self.apostrophe, Self.backtick:
                    if readStringLiteral() == nil {
                        position = bytes.count
                    }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "("):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: ")"):
                    if depth == 0 {
                        return
                    }
                    depth -= 1
                case UInt8(ascii: ","):
                    if depth == 0 {
                        return
                    }
                default:
                    break
                }
                position += 1
            }
        }

        /// A quoted or template literal at `position`; nil (position unchanged) for anything else
        /// and for an unterminated literal.
        private mutating func readStringLiteral() -> String? {
            guard position < bytes.count else {
                return nil
            }
            let delimiter = bytes[position]
            guard delimiter == Self.quote || delimiter == Self.apostrophe || delimiter == Self.backtick else {
                return nil
            }
            var index = position + 1
            var output: [UInt8] = []
            var templateDepth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Self.backslash, index + 1 < bytes.count {
                    index = Self.decodeEscape(bytes, at: index, into: &output)
                    continue
                }
                if delimiter == Self.backtick {
                    if templateDepth == 0, byte == UInt8(ascii: "$"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "{") {
                        templateDepth = 1
                        output += [byte, bytes[index + 1]]
                        index += 2
                        continue
                    }
                    if templateDepth > 0 {
                        if byte == UInt8(ascii: "{") {
                            templateDepth += 1
                        } else if byte == UInt8(ascii: "}") {
                            templateDepth -= 1
                        }
                        output.append(byte)
                        index += 1
                        continue
                    }
                }
                if byte == delimiter {
                    position = index + 1
                    return String(decoding: output, as: UTF8.self)
                }
                output.append(byte)
                index += 1
            }
            return nil
        }

        /// Decodes the escape at `index` (a backslash) and returns the index after it.
        private static func decodeEscape(_ bytes: [UInt8], at index: Int, into output: inout [UInt8]) -> Int {
            let next = bytes[index + 1]
            switch next {
            case UInt8(ascii: "n"):
                output.append(0x0A)
            case UInt8(ascii: "t"):
                output.append(0x09)
            case UInt8(ascii: "r"):
                output.append(0x0D)
            case UInt8(ascii: "b"):
                output.append(0x08)
            case UInt8(ascii: "f"):
                output.append(0x0C)
            case UInt8(ascii: "u"):
                if let (scalar, consumed) = unicodeEscape(bytes, from: index + 2) {
                    output += Array(String(Character(scalar)).utf8)
                    return index + 2 + consumed
                }
                output.append(next)
            default:
                output.append(next)
            }
            return index + 2
        }

        /// `XXXX` (with a following `\uXXXX` low surrogate when needed); nil when malformed.
        private static func unicodeEscape(_ bytes: [UInt8], from start: Int) -> (Unicode.Scalar, Int)? {
            func hex(at offset: Int) -> UInt32? {
                guard offset + 4 <= bytes.count else {
                    return nil
                }
                return UInt32(String(decoding: bytes[offset ..< offset + 4], as: UTF8.self), radix: 16)
            }
            guard let high = hex(at: start) else {
                return nil
            }
            if (0xD800 ... 0xDBFF).contains(high),
               start + 10 <= bytes.count, bytes[start + 4] == backslash, bytes[start + 5] == UInt8(ascii: "u"),
               let low = hex(at: start + 6), (0xDC00 ... 0xDFFF).contains(low),
               let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) {
                return (scalar, 10)
            }
            return Unicode.Scalar(high).map { ($0, 4) }
        }

        private static func isIdentifierByte(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
        }

        private mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) {
                position += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else {
                return false
            }
            position += 1
            return true
        }
    }
}
