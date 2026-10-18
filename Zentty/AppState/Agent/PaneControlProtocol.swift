import Foundation

/// Wire contract for `zentty pane send`, `pane send-key`, `pane read`, and
/// `zentty events`. Compiled into both the app and the CLI so the argument
/// shapes cannot drift apart.
///
/// All four ride `kind: .pane` requests, so they share the selector and
/// pane-token rules of the other pane commands. The flags below are
/// handler-private: `ParsedPaneSelectors` strips the routing selectors
/// (`--pane-id`, `--pane-index`, ...) and passes these through untouched.
enum PaneControlIPC {
    static let sendSubcommand = "send"
    static let sendKeySubcommand = "send-key"
    static let readSubcommand = "read"
    static let eventsSubcommand = "events"

    /// Raw text sent in one request. The encoded request must also fit in
    /// `maxRequestBytes`, which escape-heavy text can exceed first.
    static let maxSendTextBytes = 128 * 1024
    /// The IPC server's cap on one request line (`AgentIPCServer`).
    static let maxRequestBytes = 256 * 1024
    /// Upper bound for a `pane read` response. Scrollback can be large; the
    /// regular 256 KiB response cap would truncate it.
    static let maxReadResponseBytes = 32 * 1024 * 1024

    /// Rejects text the server would refuse, before anything is sent: the
    /// raw size, then the size of the request once JSON-encoded (escaping
    /// doubles quotes and backslashes, and turns control bytes into six).
    static func validateSendSize(text: String, request: AgentIPCRequest) throws {
        let textBytes = text.utf8.count
        guard textBytes <= maxSendTextBytes else {
            throw PaneControlIPCError.textTooLarge(bytes: textBytes, limit: maxSendTextBytes)
        }
        let requestBytes = try JSONEncoder().encode(request).count + 1
        guard requestBytes <= maxRequestBytes else {
            throw PaneControlIPCError.textTooLarge(bytes: requestBytes, limit: maxRequestBytes)
        }
    }
}

enum PaneControlIPCError: LocalizedError, Equatable {
    case missingValue(String)
    case invalidValue(String, String)
    case unexpectedArgument(String)
    case missingText
    case textTooLarge(bytes: Int, limit: Int)
    case missingKeys
    case unknownEventType(String)
    case agentBusy(agent: String)
    case agentPrompting(agent: String, interaction: String)
    case paneUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .invalidValue(let option, let value):
            "Invalid value for \(option): \(value)."
        case .unexpectedArgument(let argument):
            "Unexpected argument: \(argument)."
        case .missingText:
            "Nothing to send. Pass text after '--' or pipe it on stdin. To press Enter alone, use 'pane send-key <pane> Enter'."
        case .textTooLarge(let bytes, let limit):
            "Text is too large to send in one request (\(bytes) bytes, limit \(limit)). Split it into smaller sends."
        case .missingKeys:
            "Missing key names."
        case .unknownEventType(let pattern):
            "Unknown event type '\(pattern)'. Use a type such as agent.phase, or a family: worklane, pane, agent, attention."
        case .agentBusy(let agent):
            "\(agent) in the target pane is mid-turn. Wait for it to finish, or pass --force to send anyway."
        case .agentPrompting(let agent, let interaction):
            "\(agent) in the target pane is waiting on a prompt (\(interaction)) that input could answer. "
                + "Leave it to the user, or pass --force to send anyway."
        case .paneUnavailable(let paneID):
            "Pane \(paneID) has no running terminal to deliver input to."
        }
    }
}

/// Arguments for `pane send`. Text travels in the request's `standardInput`.
struct PaneSendIPCOptions: Equatable, Sendable {
    var target: String?
    var submit: Bool = true
    var paste: Bool = false
    var force: Bool = false

    func arguments() -> [String] {
        var arguments: [String] = []
        if let target {
            arguments += ["--target", target]
        }
        if !submit { arguments.append("--no-enter") }
        if paste { arguments.append("--paste") }
        if force { arguments.append("--force") }
        return arguments
    }

    static func parse(arguments: [String]) throws -> PaneSendIPCOptions {
        var options = PaneSendIPCOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target":
                options.target = try PaneControlArgumentReader.value(after: argument, in: arguments, at: index)
                index += 2
            case "--no-enter":
                options.submit = false
                index += 1
            case "--paste":
                options.paste = true
                index += 1
            case "--force":
                options.force = true
                index += 1
            default:
                throw PaneControlIPCError.unexpectedArgument(argument)
            }
        }
        return options
    }
}

/// Arguments for `pane send-key`. Each `--key` value is one key name.
struct PaneSendKeyIPCOptions: Equatable, Sendable {
    var target: String?
    var keys: [String] = []
    var force: Bool = false

    func arguments() -> [String] {
        var arguments: [String] = []
        if let target {
            arguments += ["--target", target]
        }
        for key in keys {
            arguments += ["--key", key]
        }
        if force { arguments.append("--force") }
        return arguments
    }

    /// Splits `pane send-key` positionals into an optional pane reference and
    /// key names. The first token is a pane reference when it looks like one
    /// (an index or a `pn_` ID), keys follow it, and no explicit pane
    /// selector was given.
    static func splitTarget(_ tokens: [String], hasExplicitPaneSelector: Bool) -> (target: String?, keys: [String]) {
        guard !hasExplicitPaneSelector, tokens.count >= 2, let first = tokens.first,
              first.hasPrefix("pn_") || Int(first) != nil
        else {
            return (nil, tokens)
        }
        return (first, Array(tokens.dropFirst()))
    }

    static func parse(arguments: [String]) throws -> PaneSendKeyIPCOptions {
        var options = PaneSendKeyIPCOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target":
                options.target = try PaneControlArgumentReader.value(after: argument, in: arguments, at: index)
                index += 2
            case "--key":
                options.keys.append(try PaneControlArgumentReader.value(after: argument, in: arguments, at: index))
                index += 2
            case "--force":
                options.force = true
                index += 1
            default:
                throw PaneControlIPCError.unexpectedArgument(argument)
            }
        }
        guard !options.keys.isEmpty else {
            throw PaneControlIPCError.missingKeys
        }
        return options
    }
}

/// Arguments for `pane read`.
struct PaneReadIPCOptions: Equatable, Sendable {
    var target: String?
    var lineLimit: Int?
    var includeScrollback: Bool = false

    func arguments() -> [String] {
        var arguments: [String] = []
        if let target {
            arguments += ["--target", target]
        }
        if let lineLimit {
            arguments += ["--lines", String(lineLimit)]
        }
        if includeScrollback { arguments.append("--scrollback") }
        return arguments
    }

    static func parse(arguments: [String]) throws -> PaneReadIPCOptions {
        var options = PaneReadIPCOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target":
                options.target = try PaneControlArgumentReader.value(after: argument, in: arguments, at: index)
                index += 2
            case "--lines":
                let raw = try PaneControlArgumentReader.value(after: argument, in: arguments, at: index)
                guard let value = Int(raw), value > 0 else {
                    throw PaneControlIPCError.invalidValue(argument, raw)
                }
                options.lineLimit = value
                index += 2
            case "--scrollback":
                options.includeScrollback = true
                index += 1
            default:
                throw PaneControlIPCError.unexpectedArgument(argument)
            }
        }
        return options
    }
}

/// Arguments for `zentty events`.
struct PaneEventsIPCOptions: Equatable, Sendable {
    var filter = PaneEventTypeFilter()

    func arguments() -> [String] {
        filter.patterns.flatMap { ["--type", $0] }
    }

    static func parse(arguments: [String]) throws -> PaneEventsIPCOptions {
        var patterns: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--type":
                let raw = try PaneControlArgumentReader.value(after: argument, in: arguments, at: index)
                let pattern = raw.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty else {
                    throw PaneControlIPCError.invalidValue(argument, raw)
                }
                guard PaneEventTypeFilter.isKnownPattern(pattern) else {
                    throw PaneControlIPCError.unknownEventType(pattern)
                }
                patterns.append(pattern)
                index += 2
            default:
                throw PaneControlIPCError.unexpectedArgument(argument)
            }
        }
        return PaneEventsIPCOptions(filter: PaneEventTypeFilter(patterns: patterns))
    }
}

/// Selects event types for a subscription. A pattern matches its exact type
/// or, as a family name, every type under it: `pane` matches `pane.created`
/// and `pane.closed`; `pane.*` is accepted as the same thing. No patterns
/// means everything. `stream.*` notices always pass so a filtered client
/// still learns about dropped events.
struct PaneEventTypeFilter: Equatable, Sendable {
    var patterns: [String] = []

    func matches(_ type: String) -> Bool {
        guard !patterns.isEmpty, !type.hasPrefix("stream.") else {
            return true
        }
        return patterns.contains { Self.pattern($0, matches: type) }
    }

    /// Whether `pattern` names at least one event type, so a typo fails
    /// instead of opening a stream that never reports anything.
    static func isKnownPattern(_ pattern: String) -> Bool {
        PaneEventType.allCases.contains { Self.pattern(pattern, matches: $0.rawValue) }
    }

    private static func pattern(_ pattern: String, matches type: String) -> Bool {
        let family = pattern.hasSuffix(".*") ? String(pattern.dropLast(2)) : pattern
        return type == family || type.hasPrefix(family + ".")
    }
}

/// Response payload of `pane read`.
struct PaneReadResult: Codable, Equatable, Sendable {
    let paneID: String
    let worklaneID: String
    let windowID: String?
    let columns: Int?
    let rows: Int?
    let includesScrollback: Bool
    let lineLimit: Int?
    let text: String
}

enum PaneControlArgumentReader {
    static func value(after option: String, in arguments: [String], at index: Int) throws -> String {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex) else {
            throw PaneControlIPCError.missingValue(option)
        }
        return arguments[valueIndex]
    }
}
