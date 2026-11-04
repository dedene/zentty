import ArgumentParser
import Foundation

struct HistoryCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Search earlier agent sessions in this project.",
        discussion: """
            Searches Claude Code, Codex, Grok and opencode sessions indexed by Agent History. \
            Run it from a Zentty pane with Agent History turned on. Results come from the pane's \
            project; --all searches every project when Settings › Agent History allows it.
            """,
        subcommands: [
            HistorySearchCommand.self,
            HistoryShowCommand.self,
        ]
    )
}

struct HistorySearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find earlier sessions by title, branch, folder, files, commands, or what was said.",
        discussion: """
            Accepts the palette operators agent:, repo:, branch:, before:YYYY-MM-DD and \
            after:YYYY-MM-DD. Put terms that start with - after --.
            """
    )

    @Argument(help: "Words to search for.")
    var query: [String] = []

    @Flag(name: .long, help: "Search every project, not just this pane's.")
    var all = false

    @Option(name: .long, help: "Only sessions from this agent: claude, codex, grok, or opencode.")
    var agent: String?

    @Option(name: .long, help: "Most results to return (1-\(HistoryIPC.maxSearchLimit), default \(HistoryIPC.defaultSearchLimit)).")
    var limit: Int?

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    func validate() throws {
        _ = try command()
    }

    mutating func run() throws {
        let command = try command()
        guard let search = try HistoryCLI.send(command).search else {
            try HistoryCLI.fail(HistoryIPC.versionSkewMessage)
        }
        if json {
            try printJSON(search)
        } else {
            print(HistoryIPCFormatting.searchText(
                search,
                query: joinedQuery,
                homeDirectory: HistoryCLI.homeDirectory,
                timeZone: .current
            ))
        }
    }

    private var joinedQuery: String {
        query.joined(separator: " ")
    }

    private func command() throws -> HistoryIPCCommand {
        try HistoryCLI.validated(.search(HistorySearchIPCOptions(
            query: joinedQuery,
            allProjects: all,
            agent: agent,
            limit: limit ?? HistoryIPC.defaultSearchLimit
        )))
    }
}

struct HistoryShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the most recent turns of one session, oldest first.",
        discussion: "Each turn is capped at 4 KB and marked [truncated] when cut."
    )

    @Argument(help: "The session id, as printed by zentty history search.")
    var sessionID: String

    @Flag(name: .long, help: "Look the session up in every project, not just this pane's.")
    var all = false

    @Option(name: .long, help: "The session's agent, when two agents share the id.")
    var agent: String?

    @Option(name: .long, help: "How many recent turns to print (1-\(HistoryIPC.maxShowTurns), default \(HistoryIPC.defaultShowTurns)).")
    var turns: Int?

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    func validate() throws {
        _ = try command()
    }

    mutating func run() throws {
        let command = try command()
        guard let show = try HistoryCLI.send(command).show else {
            try HistoryCLI.fail(HistoryIPC.versionSkewMessage)
        }
        if json {
            try printJSON(show)
        } else {
            print(HistoryIPCFormatting.showText(show, homeDirectory: HistoryCLI.homeDirectory, timeZone: .current))
        }
    }

    private func command() throws -> HistoryIPCCommand {
        try HistoryCLI.validated(.show(HistoryShowIPCOptions(
            sessionID: sessionID,
            allProjects: all,
            agent: agent,
            turns: turns ?? HistoryIPC.defaultShowTurns
        )))
    }
}

private enum HistoryCLI {
    static var homeDirectory: String {
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    /// Runs the command through the app's own parser, so the CLI rejects exactly what the app
    /// would (bounds, agent names, session ids) before connecting.
    static func validated(_ command: HistoryIPCCommand) throws -> HistoryIPCCommand {
        do {
            return try HistoryIPCCommand.parse(subcommand: command.ipcSubcommand, arguments: command.ipcArguments)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }

    static func send(_ command: HistoryIPCCommand) throws -> HistoryIPCResult {
        let environment = ProcessInfo.processInfo.environment
        let response: AgentIPCResponse?
        do {
            let request = try HistoryIPCCommand.makeRequest(command: command, environment: environment)
            // `makeRequest` already refused an empty socket path.
            let socketPath = environment["ZENTTY_INSTANCE_SOCKET"] ?? ""
            response = try AgentIPCClient.send(
                request: request,
                socketPath: socketPath,
                timeoutSeconds: HistoryIPC.clientTimeoutSeconds,
                maxResponseBytes: command.maxResponseBytes
            )
        } catch {
            try fail(message(for: error))
        }
        switch HistoryIPCClientErrorMapper.outcome(response?.result) {
        case .result(let result):
            return result
        case .failure(let message):
            try fail(message)
        }
    }

    static func message(for error: Error) -> String {
        guard let clientError = error as? AgentIPCClientError else {
            if error is DecodingError {
                return "Zentty sent an answer this zentty CLI can't read. Make sure both are the same version."
            }
            return HistoryIPCClientErrorMapper.map(error)
        }
        switch clientError {
        case .invalidResponse:
            return HistoryIPCClientErrorMapper.message(for: .connectionClosed)
        case .responseError(let error):
            return HistoryIPCClientErrorMapper.message(for: .response(code: error.code, message: error.message))
        case .requestTooLarge:
            return HistoryIPCError.responseTooLarge.localizedDescription
        case .invalidSocketPath, .connectFailed:
            return HistoryIPCClientErrorMapper.message(for: .other(clientError.localizedDescription))
        }
    }

    /// Runtime failures (as opposed to usage errors) print one line and exit non-zero.
    static func fail(_ message: String) throws -> Never {
        // The outside-pane message already names the command.
        let line = message.hasPrefix("zentty history") ? message : "zentty history: \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        throw ExitCode.failure
    }
}
