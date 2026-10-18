import Foundation

/// Where "Fork Agent Conversation" opens the forked agent. The raw value is
/// the `agents.fork_destination` config token and the `pane-fork` IPC token.
/// Shared with the CLI target.
enum AgentForkDestination: String, CaseIterable, Equatable, Sendable {
    case splitRight = "split_right"
    case splitDown = "split_down"
    case newWorklane = "new_worklane"

    static let `default`: AgentForkDestination = .splitRight
}

/// `pane-fork` IPC arguments: `[target] [--destination <token>]`. A missing
/// destination means "use the configured default".
struct AgentForkIPCArguments: Equatable, Sendable {
    enum ParseError: LocalizedError, Equatable {
        case conflictingDestinations
        case missingValue(String)
        case invalidDestination(String)
        case unexpectedArgument(String)

        var errorDescription: String? {
            switch self {
            case .conflictingDestinations:
                "Use either --down or --worklane, not both."
            case .missingValue(let option):
                "Missing value for \(option)."
            case .invalidDestination(let value):
                "Invalid fork destination '\(value)'. Use: "
                    + AgentForkDestination.allCases.map(\.rawValue).joined(separator: ", ") + "."
            case .unexpectedArgument(let argument):
                "Unexpected fork argument: \(argument)."
            }
        }
    }

    static let destinationOption = "--destination"

    var target: String?
    var destination: AgentForkDestination?

    init(target: String? = nil, destination: AgentForkDestination? = nil) {
        self.target = target
        self.destination = destination
    }

    /// Maps the CLI's `--down` / `--worklane` flags. Neither flag keeps the
    /// configured default.
    init(target: String?, down: Bool, worklane: Bool) throws {
        if down, worklane {
            throw ParseError.conflictingDestinations
        }
        self.target = target
        if down {
            destination = .splitDown
        } else if worklane {
            destination = .newWorklane
        } else {
            destination = nil
        }
    }

    var ipcArguments: [String] {
        var arguments: [String] = []
        if let target {
            arguments.append(target)
        }
        if let destination {
            arguments.append(contentsOf: [Self.destinationOption, destination.rawValue])
        }
        return arguments
    }

    static func parse(_ arguments: [String]) throws -> AgentForkIPCArguments {
        var parsed = AgentForkIPCArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == destinationOption {
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw ParseError.missingValue(argument)
                }
                let value = arguments[valueIndex]
                guard let destination = AgentForkDestination(rawValue: value) else {
                    throw ParseError.invalidDestination(value)
                }
                parsed.destination = destination
                index += 2
                continue
            }
            guard parsed.target == nil, !argument.hasPrefix("--") else {
                throw ParseError.unexpectedArgument(argument)
            }
            parsed.target = argument
            index += 1
        }
        return parsed
    }
}
