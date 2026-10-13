import Foundation

enum AgentTool: Equatable, Sendable {
    case zentty
    case amp
    case claudeCode
    case codex
    case copilot
    case cursor
    case droid
    case gemini
    case kimi
    case openCode
    case pi
    case omp
    case grok
    case agy
    case hermes
    case vibe
    case devin
    case muse
    case smallHarness
    case custom(String)

    var displayName: String {
        switch self {
        case .zentty:
            return "Zentty"
        case .amp:
            return "Amp"
        case .claudeCode:
            return "Claude Code"
        case .codex:
            return "Codex"
        case .copilot:
            return "Copilot"
        case .cursor:
            return "Cursor"
        case .droid:
            return "Droid"
        case .gemini:
            return "Gemini"
        case .kimi:
            return "Kimi"
        case .openCode:
            return "OpenCode"
        case .pi:
            return "Pi"
        case .omp:
            return "OMP"
        case .grok:
            return "Grok"
        case .agy:
            return "Antigravity"
        case .hermes:
            return "Hermes Agent"
        case .vibe:
            return "Mistral Vibe"
        case .devin:
            return "Devin"
        case .muse:
            return "Muse Code"
        case .smallHarness:
            return "Small Harness"
        case .custom(let name):
            return name
        }
    }

    /// All builtin (non-manifest) tools, used to detect displayName collisions.
    static let builtinTools: [AgentTool] = [
        .zentty, .amp, .claudeCode, .codex, .copilot, .cursor, .droid, .gemini,
        .kimi, .openCode, .pi, .omp, .grok, .agy, .hermes, .vibe, .devin,
        .muse, .smallHarness,
    ]

    static let builtinDisplayNames: Set<String> = Set(builtinTools.map(\.displayName))

    static func resolve(named rawName: String?) -> AgentTool? {
        guard let normalized = normalized(rawName) else {
            return nil
        }

        if let tool = resolveKnownTool(named: normalized, includeHookDrivenOnly: true) {
            return tool
        }

        guard let rawName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return nil
        }

        return .custom(rawName)
    }

    static func resolveKnown(named rawName: String?) -> AgentTool? {
        guard let normalized = normalized(rawName) else {
            return nil
        }

        return resolveKnownTool(named: normalized, includeHookDrivenOnly: false)
    }

    private static func resolveKnownTool(named normalized: String, includeHookDrivenOnly: Bool) -> AgentTool? {
        for matcher in knownToolMatchers {
            guard includeHookDrivenOnly || !matcher.isHookDrivenOnly else { continue }
            if matcher.matches(normalized) {
                return matcher.tool
            }
        }
        return AgentManifestRegistry.provider().tool(matchingProcessNameOrTitle: normalized)
    }

    private struct ToolNameMatcher: Sendable {
        let tool: AgentTool
        let isHookDrivenOnly: Bool
        let match: Match

        func matches(_ normalized: String) -> Bool {
            switch match {
            case .contains(let needle):
                return normalized.contains(needle)
            case .containsAny(let needles):
                return needles.contains { normalized.contains($0) }
            case .leadingToken(let tokens):
                return matchesLeadingToken(normalized, tokens: tokens)
            case .pi:
                return matchesPi(normalized)
            }
        }
    }

    private enum Match: Sendable {
        case contains(String)
        case containsAny([String])
        case leadingToken([String])
        case pi
    }

    private static let knownToolMatchers: [ToolNameMatcher] = [
        ToolNameMatcher(tool: .amp, isHookDrivenOnly: false, match: .leadingToken(["amp"])),
        ToolNameMatcher(tool: .claudeCode, isHookDrivenOnly: false, match: .contains("claude")),
        ToolNameMatcher(tool: .codex, isHookDrivenOnly: false, match: .contains("codex")),
        // Keep hook-driven-only tools out of metadata recognition so generic
        // terminal-progress fallback still shows Running when hooks are absent.
        ToolNameMatcher(tool: .copilot, isHookDrivenOnly: true, match: .contains("copilot")),
        ToolNameMatcher(tool: .cursor, isHookDrivenOnly: true, match: .contains("cursor")),
        ToolNameMatcher(tool: .droid, isHookDrivenOnly: false, match: .contains("droid")),
        ToolNameMatcher(tool: .gemini, isHookDrivenOnly: false, match: .contains("gemini")),
        ToolNameMatcher(tool: .kimi, isHookDrivenOnly: false, match: .contains("kimi")),
        ToolNameMatcher(tool: .openCode, isHookDrivenOnly: false, match: .containsAny(["opencode", "open code"])),
        ToolNameMatcher(tool: .pi, isHookDrivenOnly: false, match: .pi),
        ToolNameMatcher(tool: .omp, isHookDrivenOnly: false, match: .leadingToken(["omp"])),
        ToolNameMatcher(tool: .grok, isHookDrivenOnly: false, match: .leadingToken(["grok", "grok-build"])),
        ToolNameMatcher(tool: .agy, isHookDrivenOnly: false, match: .leadingToken(["agy", "antigravity"])),
        ToolNameMatcher(tool: .hermes, isHookDrivenOnly: false, match: .leadingToken(["hermes"])),
        // "Mistral Vibe" normalizes to "mistral vibe" (leading token "mistral");
        // the bare binary surfaces as "vibe". Match both leading tokens.
        ToolNameMatcher(tool: .vibe, isHookDrivenOnly: false, match: .leadingToken(["vibe", "mistral"])),
        ToolNameMatcher(tool: .devin, isHookDrivenOnly: false, match: .leadingToken(["devin"])),
        // The launcher script `muse` execs `muse-bin-<version>`; both share the
        // leading token "muse", as does the "Muse Code" display name.
        ToolNameMatcher(tool: .muse, isHookDrivenOnly: false, match: .leadingToken(["muse"])),
        ToolNameMatcher(tool: .smallHarness, isHookDrivenOnly: false, match: .containsAny(["small-harness", "small harness", "smallharness"])),
    ]

    private static func matchesPi(_ normalized: String) -> Bool {
        // Pi's binary name is short ("pi") and its titlebar extension uses
        // the Greek letter π, sometimes prefixed with a braille spinner
        // frame (e.g. "⠋ π - cwd"). Split on whitespace and require an
        // exact token match so "pip", "pizza", "apipie", "pi.py" etc.
        // don't get caught.
        for token in normalized.split(separator: " ") {
            if token == "pi" || token == "π" { return true }
        }
        return false
    }

    static func matchesLeadingToken(_ normalized: String, tokens expectedTokens: [String]) -> Bool {
        guard let token = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first else {
            return false
        }
        return expectedTokens.contains(String(token))
    }

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
