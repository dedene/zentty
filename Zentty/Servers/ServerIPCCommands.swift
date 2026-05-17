import Foundation

enum ServerIPCCommand: Equatable, Sendable {
    case set(rawURL: String, pid: Int?, json: Bool)
    case clear(json: Bool)
    case list(json: Bool)
    case open(rawURL: String?, browserID: String?, json: Bool)
    case watchSet(rawURL: String, pid: Int?, json: Bool)
    case watchClear(json: Bool)
    case watch(command: [String])

    static let outsidePaneMessage = "zentty server commands must run inside a Zentty pane."

    var ipcSubcommand: String? {
        switch self {
        case .set:
            "server-set"
        case .clear:
            "server-clear"
        case .list:
            "server-list"
        case .open:
            "server-open"
        case .watchSet:
            "server-watch-set"
        case .watchClear:
            "server-watch-clear"
        case .watch:
            nil
        }
    }

    var ipcArguments: [String] {
        switch self {
        case .set(let rawURL, let pid, let json):
            var arguments = [rawURL]
            if let pid {
                arguments.append(contentsOf: ["--pid", String(pid)])
            }
            if json {
                arguments.append("--json")
            }
            return arguments
        case .clear(let json), .list(let json):
            return json ? ["--json"] : []
        case .open(let rawURL, let browserID, let json):
            var arguments: [String] = []
            if let rawURL {
                arguments.append(rawURL)
            }
            if let browserID {
                arguments.append(contentsOf: ["--browser", browserID])
            }
            if json {
                arguments.append("--json")
            }
            return arguments
        case .watchSet(let rawURL, let pid, let json):
            var arguments = [rawURL]
            if let pid {
                arguments.append(contentsOf: ["--pid", String(pid)])
            }
            if json {
                arguments.append("--json")
            }
            return arguments
        case .watchClear(let json):
            return json ? ["--json"] : []
        case .watch(let command):
            return command
        }
    }

    var expectsResponse: Bool {
        switch self {
        case .set(_, _, let json), .clear(let json), .list(let json), .open(_, _, let json),
             .watchSet(_, _, let json), .watchClear(let json):
            json
        case .watch:
            false
        }
    }

    static func isServerSubcommand(_ subcommand: String) -> Bool {
        ["server-set", "server-clear", "server-list", "server-open", "server-watch-set", "server-watch-clear"].contains(subcommand)
    }

    static func parse(arguments: [String]) throws -> ServerIPCCommand {
        guard let subcommand = arguments.first else {
            throw ServerIPCCommandError.missingSubcommand
        }

        let trailing = Array(arguments.dropFirst())
        switch subcommand {
        case "set":
            return try parseSet(trailing)
        case "clear":
            return try parseNoArgumentCommand(trailing, makeCommand: ServerIPCCommand.clear)
        case "list":
            return try parseNoArgumentCommand(trailing, makeCommand: ServerIPCCommand.list)
        case "open":
            return try parseOpen(trailing)
        case "watch-set":
            let parsed = try parseSet(trailing)
            guard case .set(let rawURL, let pid, let json) = parsed else {
                throw ServerIPCCommandError.invalidWatchSet
            }
            return .watchSet(rawURL: rawURL, pid: pid, json: json)
        case "watch-clear":
            return try parseNoArgumentCommand(trailing, makeCommand: ServerIPCCommand.watchClear)
        case "watch":
            return try parseWatch(trailing)
        default:
            throw ServerIPCCommandError.unsupportedSubcommand(subcommand)
        }
    }

    static func makeRequest(
        command: ServerIPCCommand,
        environment: [String: String],
        id: String = UUID().uuidString
    ) throws -> AgentIPCRequest {
        guard environment["ZENTTY_INSTANCE_SOCKET"]?.isEmpty == false else {
            throw ServerIPCCommandError.outsidePane
        }
        guard hasRequiredRoutingEnvironment(environment) else {
            throw ServerIPCCommandError.outsidePane
        }
        guard let subcommand = command.ipcSubcommand else {
            throw ServerIPCCommandError.watchRequiresRunner
        }

        return AgentIPCRequest(
            id: id,
            kind: .server,
            arguments: command.ipcArguments,
            standardInput: nil,
            environment: forwardedEnvironment(from: environment),
            expectsResponse: command.expectsResponse,
            subcommand: subcommand
        )
    }

    static func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: forwardedEnvironmentKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
    }

    private static func parseSet(_ arguments: [String]) throws -> ServerIPCCommand {
        var rawURL: String?
        var pid: Int?
        var json = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--pid":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw ServerIPCCommandError.missingValue(argument)
                }
                guard let parsedPID = Int(arguments[valueIndex]), parsedPID > 0 else {
                    throw ServerIPCCommandError.invalidPID(arguments[valueIndex])
                }
                pid = parsedPID
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                guard rawURL == nil else {
                    throw ServerIPCCommandError.unexpectedArgument(argument)
                }
                rawURL = argument
                index += 1
            }
        }

        guard let rawURL else {
            throw ServerIPCCommandError.missingURL
        }

        return .set(rawURL: rawURL, pid: pid, json: json)
    }

    private static func parseNoArgumentCommand(
        _ arguments: [String],
        makeCommand: (Bool) -> ServerIPCCommand
    ) throws -> ServerIPCCommand {
        var json = false
        for argument in arguments {
            guard argument == "--json" else {
                throw ServerIPCCommandError.unexpectedArgument(argument)
            }
            json = true
        }
        return makeCommand(json)
    }

    private static func parseOpen(_ arguments: [String]) throws -> ServerIPCCommand {
        var rawURL: String?
        var browserID: String?
        var json = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--browser":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw ServerIPCCommandError.missingValue(argument)
                }
                browserID = arguments[valueIndex]
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                guard rawURL == nil else {
                    throw ServerIPCCommandError.unexpectedArgument(argument)
                }
                rawURL = argument
                index += 1
            }
        }

        return .open(rawURL: rawURL, browserID: browserID, json: json)
    }

    private static func parseWatch(_ arguments: [String]) throws -> ServerIPCCommand {
        let command = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        guard !command.isEmpty else {
            throw ServerIPCCommandError.missingWatchCommand
        }
        return .watch(command: command)
    }

    private static func hasRequiredRoutingEnvironment(_ environment: [String: String]) -> Bool {
        ["ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"].allSatisfy { key in
            environment[key]?.isEmpty == false
        }
    }

    private static let forwardedEnvironmentKeys = [
        "ZENTTY_WINDOW_ID",
        "ZENTTY_WORKLANE_ID",
        "ZENTTY_PANE_ID",
        "ZENTTY_PANE_TOKEN",
        "ZENTTY_INSTANCE_ID",
    ]
}

enum ServerIPCCommandError: LocalizedError, Equatable {
    case missingSubcommand
    case unsupportedSubcommand(String)
    case missingURL
    case missingValue(String)
    case invalidPID(String)
    case unexpectedArgument(String)
    case missingWatchCommand
    case invalidWatchSet
    case outsidePane
    case watchRequiresRunner

    var errorDescription: String? {
        switch self {
        case .missingSubcommand:
            "Missing server subcommand."
        case .unsupportedSubcommand(let subcommand):
            "Unsupported server subcommand: \(subcommand)"
        case .missingURL:
            "Missing server URL."
        case .missingValue(let option):
            "Missing value for \(option)."
        case .invalidPID(let rawValue):
            "Invalid PID '\(rawValue)'."
        case .unexpectedArgument(let argument):
            "Unexpected argument '\(argument)'."
        case .missingWatchCommand:
            "Missing command after zentty server watch --."
        case .invalidWatchSet:
            "Invalid server watch registration."
        case .outsidePane:
            ServerIPCCommand.outsidePaneMessage
        case .watchRequiresRunner:
            "zentty server watch must be handled by the watch runner."
        }
    }
}
