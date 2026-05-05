import Foundation

/// Renders tmux-style format strings (the `#{var}` and `#{?cond,a,b}` syntax)
/// against a flat key/value context. The tmux compatibility layer
/// produces output with the same templating; Claude Code parses it back into
/// pane lists and metadata.
///
/// Supported syntax:
/// - `#{name}` — substitute the value bound to `name`, or empty if unbound.
/// - `#{?name,whenTrue,whenFalse}` — `whenTrue` if `name` is bound to a
///   non-empty string, otherwise `whenFalse`.
/// - `#X` — short-form alias for a subset of common variables (e.g. `#S` →
///   `session_name`, `#I` → `window_index`, `#P` → `pane_index`). Unknown
///   short tokens pass through verbatim, matching tmux.
/// - `##` — literal `#`.
///
/// We deliberately do not implement the full tmux format DSL (loops,
/// modifiers, expressions); Claude Code only emits the variable, conditional,
/// and short-form variants above.
enum TmuxFormatRenderer {
    static func render(_ template: String, context: [String: String]) -> String {
        var result = ""
        var iterator = template.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            guard scalar == "#" else {
                result.unicodeScalars.append(scalar)
                continue
            }

            guard let next = iterator.next() else {
                result.unicodeScalars.append(scalar)
                break
            }

            switch next {
            case "#":
                result.unicodeScalars.append("#")
            case "{":
                let body = consumeBraceBody(&iterator)
                result.append(expand(body: body, context: context))
            default:
                if let longName = shortTokenName(for: next) {
                    result.append(context[longName] ?? "")
                } else {
                    result.unicodeScalars.append(scalar)
                    result.unicodeScalars.append(next)
                }
            }
        }

        return result
    }

    /// Maps tmux's single-character format tokens (`#S`, `#I`, …) to the
    /// long-form variable names used in the context dictionary. We cover the
    /// tokens Claude Code's harness probes plus a few common neighbours; the
    /// list intentionally stays small — anything not mapped falls back to
    /// passing the original `#X` through unchanged.
    static func shortTokenName(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "S": return "session_name"
        case "I": return "window_index"
        case "P": return "pane_index"
        case "D": return "pane_id"
        case "T": return "pane_title"
        case "W": return "window_name"
        case "F": return "window_flags"
        case "H": return "host_short"
        case "h": return "host"
        default: return nil
        }
    }

    private static func consumeBraceBody(
        _ iterator: inout String.UnicodeScalarView.Iterator
    ) -> String {
        var depth = 1
        var body = ""
        while let scalar = iterator.next() {
            if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 {
                    return body
                }
            }
            body.unicodeScalars.append(scalar)
        }
        return body
    }

    private static func expand(body: String, context: [String: String]) -> String {
        if body.hasPrefix("?") {
            return expandConditional(body: String(body.dropFirst()), context: context)
        }
        return context[body] ?? ""
    }

    private static func expandConditional(body: String, context: [String: String]) -> String {
        // `name,whenTrue,whenFalse` — split on top-level commas only.
        let parts = splitTopLevel(body, separator: ",")
        guard parts.count == 3 else {
            return ""
        }
        let value = context[parts[0]] ?? ""
        return render(value.isEmpty ? parts[2] : parts[1], context: context)
    }

    private static func splitTopLevel(_ source: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in source {
            if character == "{" {
                depth += 1
                current.append(character)
            } else if character == "}" {
                depth -= 1
                current.append(character)
            } else if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}
