import Foundation

/// Tiny helpers that relax a JSON document enough for parsers that normally
/// insist on strict JSON. They accept JSON-with-comments (`//` and `/* */`)
/// and trailing commas — both common when users hand-edit agent config files.
///
/// Callers should still try strict parsing first and fall back to these only
/// when that fails, so genuine syntax errors surface clearly.
enum JSONCRelaxedParse {
    /// Strip `//` and `/* */` comments, preserving content inside string
    /// literals. Returns `nil` if the input isn't valid UTF-8.
    static func stripComments(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = ""
        var iterator = text.makeIterator()
        var pending = iterator.next()
        var inString = false
        var escaping = false
        var lookahead: Character?

        func advance() {
            pending = lookahead ?? iterator.next()
            lookahead = nil
        }

        while let character = pending {
            if inString {
                output.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                advance()
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                advance()
                continue
            }

            if character == "/" {
                lookahead = iterator.next()
                if lookahead == "/" {
                    advance()
                    while let next = pending, next != "\n", next != "\r" {
                        advance()
                    }
                    continue
                }
                if lookahead == "*" {
                    advance()
                    while let next = pending {
                        if next == "*" {
                            lookahead = iterator.next()
                            if lookahead == "/" {
                                advance()
                                advance()
                                break
                            }
                        }
                        advance()
                    }
                    continue
                }
                output.append(character)
                advance()
                continue
            }

            output.append(character)
            advance()
        }

        return output.data(using: .utf8)
    }

    /// Remove commas that appear immediately before `}` or `]`, which strict
    /// JSON rejects.
    static func stripTrailingCommas(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let characters = Array(text)
        var output = ""
        var inString = false
        var escaping = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < characters.count, characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return output.data(using: .utf8)
    }
}
