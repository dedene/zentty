import Foundation

/// Renders tmux-style format strings (the `#{var}` and `#{?cond,a,b}` syntax)
/// against a flat key/value context. The tmux compatibility layer
/// produces output with the same templating; agent tools parse it back into
/// pane lists and metadata.
///
/// Supported syntax:
/// - `#{name}` — substitute the value bound to `name`, or empty if unbound.
/// - `#{?cond,whenTrue,whenFalse}` — `cond` is a variable name or a nested
///   `#{...}` format. It is true when the result is neither empty nor `0`,
///   matching tmux.
/// - Comparison and logic operators: `#{==:a,b}`, `#{!=:a,b}`, `#{<:a,b}`,
///   `#{>:a,b}`, `#{<=:a,b}`, `#{>=:a,b}`, `#{&&:a,b}`, `#{||:a,b}`. Both
///   operands are expanded as formats first; the result is `1` or `0`.
/// - `#{m:pattern,string}` — `1` when `string` matches the glob `pattern`.
/// - Modifiers on a variable: `#{=N:var}` / `#{=-N:var}` (truncate to the
///   first or last N characters), `#{b:var}` / `#{d:var}` (basename /
///   dirname), `#{q:var}` (shell-escape), `#{n:var}` (length), `#{E:var}`
///   (expand the value as a format), `#{l:text}` (literal).
/// - `#X` — short-form alias for a subset of common variables (e.g. `#S` →
///   `session_name`, `#I` → `window_index`, `#P` → `pane_index`). Unknown
///   short tokens pass through verbatim, matching tmux.
/// - `##` — literal `#`.
///
/// Loops (`#{S:...}`, `#{W:...}`), time formats and regex substitution are not
/// implemented; the tools the shim serves do not emit them.
enum TmuxFormatRenderer {
    /// Nesting limit for `#{E:…}` and nested formats. Values come from user
    /// options and pane titles that tools and programs set, so a value that
    /// expands itself must stop instead of recursing on the main thread.
    /// Expansion past the limit renders empty.
    static let maxDepth = 32

    static func render(_ template: String, context: [String: String]) -> String {
        render(template, context: context, depth: 0, budget: ExpansionBudget())
    }

    /// Caps the total number of `#{…}` expansions in one render, so a value
    /// that expands itself twice cannot grow the work exponentially.
    private final class ExpansionBudget {
        var remaining = 10_000
    }

    private static func render(
        _ template: String,
        context: [String: String],
        depth: Int,
        budget: ExpansionBudget
    ) -> String {
        guard depth < maxDepth, budget.remaining > 0 else {
            return ""
        }
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
                budget.remaining -= 1
                result.append(expand(body: body, context: context, depth: depth + 1, budget: budget))
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

    /// tmux truthiness: a value is true when it is neither empty nor `0`.
    static func isTruthy(_ value: String) -> Bool {
        !value.isEmpty && value != "0"
    }

    /// Maps tmux's single-character format tokens (`#S`, `#I`, …) to the
    /// long-form variable names used in the context dictionary. We cover the
    /// tokens agent tools probe plus a few common neighbours; the list
    /// intentionally stays small — anything not mapped falls back to passing
    /// the original `#X` through unchanged.
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

    private static func expand(
        body: String,
        context: [String: String],
        depth: Int,
        budget: ExpansionBudget
    ) -> String {
        if body.hasPrefix("?") {
            return expandConditional(body: String(body.dropFirst()), context: context, depth: depth, budget: budget)
        }
        if let (modifier, operand) = splitModifier(body) {
            return applyModifier(modifier, operand: operand, context: context, depth: depth, budget: budget)
        }
        return context[body] ?? ""
    }

    private static func expandConditional(
        body: String,
        context: [String: String],
        depth: Int,
        budget: ExpansionBudget
    ) -> String {
        // `cond,whenTrue,whenFalse` — split on top-level commas only.
        let parts = splitTopLevel(body, separator: ",")
        guard parts.count == 2 || parts.count == 3 else {
            return ""
        }
        let condition = parts[0].hasPrefix("#{")
            ? render(parts[0], context: context, depth: depth, budget: budget)
            : (context[parts[0]] ?? "")
        if isTruthy(condition) {
            return render(parts[1], context: context, depth: depth, budget: budget)
        }
        return parts.count == 3 ? render(parts[2], context: context, depth: depth, budget: budget) : ""
    }

    private static let binaryOperators: Set<String> = ["==", "!=", "<", ">", "<=", ">=", "&&", "||", "m"]
    private static let unaryModifiers: Set<String> = ["l", "b", "d", "q", "n", "E"]

    /// Splits `modifier:operand` when the prefix before the first `:` is a
    /// modifier this renderer knows. Variable names never contain a colon, so
    /// a plain `#{pane_id}` never matches.
    private static func splitModifier(_ body: String) -> (String, String)? {
        guard let colon = body.firstIndex(of: ":") else {
            return nil
        }
        let modifier = String(body[..<colon])
        let operand = String(body[body.index(after: colon)...])
        if binaryOperators.contains(modifier) || unaryModifiers.contains(modifier) {
            return (modifier, operand)
        }
        if modifier.hasPrefix("="), Int(modifier.dropFirst()) != nil {
            return (modifier, operand)
        }
        return nil
    }

    private static func applyModifier(
        _ modifier: String,
        operand: String,
        context: [String: String],
        depth: Int,
        budget: ExpansionBudget
    ) -> String {
        if binaryOperators.contains(modifier) {
            let operands = splitTopLevel(operand, separator: ",")
            guard operands.count == 2 else {
                return ""
            }
            let left = render(operands[0], context: context, depth: depth, budget: budget)
            let right = render(operands[1], context: context, depth: depth, budget: budget)
            return evaluate(modifier, left, right) ? "1" : "0"
        }

        if modifier == "l" {
            return operand
        }
        let value = operand.hasPrefix("#{") ? render(operand, context: context, depth: depth, budget: budget) : (context[operand] ?? "")
        switch modifier {
        case "b":
            return value.isEmpty ? "" : (value as NSString).lastPathComponent
        case "d":
            return value.isEmpty ? "" : (value as NSString).deletingLastPathComponent
        case "q":
            return shellEscaped(value)
        case "n":
            return String(value.count)
        case "E":
            return render(value, context: context, depth: depth, budget: budget)
        default:
            guard let length = Int(modifier.dropFirst()) else {
                return value
            }
            return length >= 0 ? String(value.prefix(length)) : String(value.suffix(-length))
        }
    }

    private static func evaluate(_ modifier: String, _ left: String, _ right: String) -> Bool {
        switch modifier {
        case "==": return left == right
        case "!=": return left != right
        case "&&": return isTruthy(left) && isTruthy(right)
        case "||": return isTruthy(left) || isTruthy(right)
        case "m": return fnmatch(left, right, 0) == 0
        default:
            // tmux compares numerically when both sides are numbers.
            if let lhs = Double(left), let rhs = Double(right) {
                return compare(modifier, lhs, rhs)
            }
            return compare(modifier, left, right)
        }
    }

    private static func compare<T: Comparable>(_ modifier: String, _ lhs: T, _ rhs: T) -> Bool {
        switch modifier {
        case "<": return lhs < rhs
        case ">": return lhs > rhs
        case "<=": return lhs <= rhs
        case ">=": return lhs >= rhs
        default: return false
        }
    }

    private static func shellEscaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character.isLetter || character.isNumber || "@%_-+=:,./".contains(character) {
                escaped.append(character)
            } else {
                escaped.append("\\")
                escaped.append(character)
            }
        }
        return escaped
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
