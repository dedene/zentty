import Foundation

/// Turns raw transcript text into the text Agent History stores and shows (`messages.text`).
///
/// `displayText` runs after redaction and before `AgentHistorySearchText.normalize`:
/// - terminal escape sequences (CSI, OSC, other ESC sequences) are dropped;
/// - CRLF and lone CR become LF;
/// - other C0/C1 control characters and DEL are dropped (tab and LF stay);
/// - whitespace-only lines count as blank, and runs of 3+ blank lines shrink to 2;
/// - leading and trailing whitespace is trimmed; an empty result is nil;
/// - text longer than `maxStoredCharacters` is cut at a grapheme boundary and ends in `…`.
enum AgentHistoryDisplayText {
    static let maxStoredCharacters = 32_768
    static let maxBlankLines = 2
    static let ellipsis: Character = "…"

    static func displayText(_ raw: String) -> String? {
        let cleaned = stripEscapesAndControls(raw)
        let collapsed = collapseBlankLines(cleaned)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return truncated(trimmed, limit: maxStoredCharacters)
    }

    /// A one-line title from a prompt's display text: whitespace runs (newlines included)
    /// become one space, then the text is cut to `limit` Characters ending in `…`.
    static func firstPromptTitle(_ display: String, limit: Int = 80) -> String {
        var line = ""
        var pendingSpace = false
        for character in display {
            if character.isWhitespace {
                pendingSpace = !line.isEmpty
                continue
            }
            if pendingSpace {
                line.append(" ")
                pendingSpace = false
            }
            line.append(character)
        }
        return truncated(line, limit: limit)
    }

    /// True when the whole text is agent plumbing rather than something a person typed:
    /// one or more sibling `<tag>…</tag>` blocks separated only by whitespace (Claude
    /// command/caveat envelopes, `<system-reminder>`, Codex `<environment_context>`), or
    /// Codex's injected `# AGENTS.md instructions` message.
    static func isEnvelope(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        var position = skipWhitespace(utf8, from: 0)
        guard position < utf8.count else {
            return false
        }
        if utf8[position...].starts(with: Array("# AGENTS.md instructions".utf8)) {
            return true
        }
        while position < utf8.count {
            guard let end = endOfElement(utf8, at: position) else {
                return false
            }
            position = skipWhitespace(utf8, from: end)
        }
        return true
    }

    /// `/name args` from a Claude slash-command envelope
    /// (`<command-name>/name</command-name>…<command-args>args</command-args>`); nil when the
    /// text has no non-empty `command-name`. A missing leading `/` is added.
    static func slashCommand(fromEnvelope text: String) -> String? {
        guard let rawName = tagContent("command-name", in: text) else {
            return nil
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return nil
        }
        let command = name.hasPrefix("/") ? name : "/" + name
        let arguments = (tagContent("command-args", in: text) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return arguments.isEmpty ? command : command + " " + arguments
    }

    // MARK: - Truncation

    /// `text` unchanged when it has at most `limit` Characters; otherwise the first
    /// `limit - 1` Characters (trailing whitespace dropped) plus `…`.
    static func truncated(_ text: String, limit: Int) -> String {
        guard limit > 0 else {
            return ""
        }
        guard let cut = text.index(text.startIndex, offsetBy: limit - 1, limitedBy: text.endIndex),
              cut < text.endIndex,
              text.index(after: cut) < text.endIndex
        else {
            return text
        }
        var head = String(text[..<cut])
        while let last = head.last, last.isWhitespace {
            head.removeLast()
        }
        head.append(ellipsis)
        return head
    }

    // MARK: - Escapes and control characters

    private enum EscapeState {
        case text
        case escape            // after ESC
        case escapeIntermediate // ESC followed by 0x20–0x2F bytes
        case csi               // ESC [ … final byte
        case string            // OSC / DCS / SOS / PM / APC, until BEL or ST
        case stringEscape      // ESC inside a string sequence
    }

    private static func stripEscapesAndControls(_ raw: String) -> String {
        var output = String.UnicodeScalarView()
        var state = EscapeState.text
        var previousWasCR = false

        for scalar in raw.unicodeScalars {
            let current = scalar
            var reprocess = true
            while reprocess {
                reprocess = false
                let value = current.value
                switch state {
                case .text:
                    if value == 0x1B {
                        state = .escape
                        previousWasCR = false
                    } else if value == 0x0D {
                        output.append("\n")
                        previousWasCR = true
                    } else if value == 0x0A {
                        if !previousWasCR {
                            output.append("\n")
                        }
                        previousWasCR = false
                    } else {
                        previousWasCR = false
                        if !isDroppedControl(value) {
                            output.append(current)
                        }
                    }
                case .escape:
                    switch value {
                    case 0x5B: // [
                        state = .csi
                    case 0x5D, 0x50, 0x58, 0x5E, 0x5F: // ] P X ^ _
                        state = .string
                    case 0x20...0x2F:
                        state = .escapeIntermediate
                    case 0x30...0x7E:
                        state = .text
                    default:
                        state = .text
                        reprocess = true
                    }
                case .escapeIntermediate:
                    switch value {
                    case 0x20...0x2F:
                        break
                    case 0x30...0x7E:
                        state = .text
                    default:
                        state = .text
                        reprocess = true
                    }
                case .csi:
                    switch value {
                    case 0x20...0x3F:
                        break
                    case 0x40...0x7E:
                        state = .text
                    default:
                        state = .text
                        reprocess = true
                    }
                case .string:
                    switch value {
                    case 0x07:
                        state = .text
                    case 0x1B:
                        state = .stringEscape
                    case 0x0A, 0x0D:
                        // A newline never belongs to a terminal string; treat the sequence as
                        // broken so an unterminated OSC can't swallow the rest of a message.
                        state = .text
                        reprocess = true
                    default:
                        break
                    }
                case .stringEscape:
                    if value == 0x5C { // \ (ST)
                        state = .text
                    } else {
                        state = .escape
                        reprocess = true
                    }
                }
            }
        }
        return String(output)
    }

    /// C0 controls other than tab and LF, DEL, and C1 controls.
    private static func isDroppedControl(_ value: UInt32) -> Bool {
        switch value {
        case 0x09, 0x0A:
            return false
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        default:
            return false
        }
    }

    private static func collapseBlankLines(_ text: String) -> String {
        guard text.contains("\n") else {
            return text
        }
        var lines: [Substring] = []
        var blankRun = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                blankRun += 1
                if blankRun <= maxBlankLines {
                    lines.append("")
                }
            } else {
                blankRun = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Envelope parsing (UTF-8 bytes)

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var position = start
        while position < bytes.count, isWhitespace(bytes[position]) {
            position += 1
        }
        return position
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isNameStart(byte) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F || byte == 0x3A || byte == 0x2E
    }

    private struct Tag {
        let name: ArraySlice<UInt8>
        let isClosing: Bool
        let isSelfClosing: Bool
        let end: Int
    }

    /// Parses `<name …>`, `</name>` or `<name …/>` at `position`.
    private static func tag(_ bytes: [UInt8], at position: Int) -> Tag? {
        guard position < bytes.count, bytes[position] == 0x3C else {
            return nil
        }
        var cursor = position + 1
        let isClosing = cursor < bytes.count && bytes[cursor] == 0x2F
        if isClosing {
            cursor += 1
        }
        guard cursor < bytes.count, isNameStart(bytes[cursor]) else {
            return nil
        }
        let nameStart = cursor
        while cursor < bytes.count, isNameByte(bytes[cursor]) {
            cursor += 1
        }
        let name = bytes[nameStart..<cursor]
        guard cursor < bytes.count else {
            return nil
        }
        if bytes[cursor] != 0x3E && !isWhitespace(bytes[cursor]) && bytes[cursor] != 0x2F {
            return nil
        }
        // Attributes: up to the first `>` on the same tag (no `<` allowed inside).
        while cursor < bytes.count, bytes[cursor] != 0x3E {
            if bytes[cursor] == 0x3C {
                return nil
            }
            cursor += 1
        }
        guard cursor < bytes.count else {
            return nil
        }
        let isSelfClosing = !isClosing && bytes[cursor - 1] == 0x2F
        return Tag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing, end: cursor + 1)
    }

    /// The index just past the element opened at `position`, matching nested same-name tags.
    private static func endOfElement(_ bytes: [UInt8], at position: Int) -> Int? {
        guard let open = tag(bytes, at: position), !open.isClosing else {
            return nil
        }
        if open.isSelfClosing {
            return open.end
        }
        var depth = 1
        var cursor = open.end
        while cursor < bytes.count {
            if bytes[cursor] == 0x3C, let next = tag(bytes, at: cursor) {
                if next.name.elementsEqual(open.name) {
                    if next.isClosing {
                        depth -= 1
                        if depth == 0 {
                            return next.end
                        }
                    } else if !next.isSelfClosing {
                        depth += 1
                    }
                }
                cursor = next.end
            } else {
                cursor += 1
            }
        }
        return nil
    }

    /// The text between `<name>` and `</name>` (or the end of the text when unterminated).
    private static func tagContent(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>") else {
            return nil
        }
        let rest = text[open.upperBound...]
        if let close = rest.range(of: "</\(name)>") {
            return String(rest[..<close.lowerBound])
        }
        return String(rest)
    }
}
