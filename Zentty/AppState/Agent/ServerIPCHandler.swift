import AppKit
import Foundation

enum ServerIPCHandler {
    static func handle(
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let subcommand = request.subcommand else {
            throw AgentIPCError.invalidMessage
        }

        let command = try parseCommand(subcommand: subcommand, arguments: request.arguments)

        var result: Result<AgentIPCResponseResult, Error>!
        DispatchQueue.main.sync {
            result = Result {
                try MainActorShim.assumeIsolated {
                    try Self.dispatch(command: command, target: target)
                }
            }
        }
        return try result.get()
    }

    @MainActor
    private static func dispatch(
        command: ServerIPCCommand,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let windowController = target.windowID.flatMap(appDelegate.windowController(with:))
                ?? appDelegate.windowController(containingWorklane: target.worklaneID) else {
            return AgentIPCResponseResult()
        }

        return try windowController.handleServerIPCCommand(command, target: target)
    }

    static func parseCommand(
        subcommand: String,
        arguments: [String]
    ) throws -> ServerIPCCommand {
        switch subcommand {
        case "server-set":
            return try ServerIPCCommand.parse(arguments: ["set"] + arguments)
        case "server-clear":
            return try ServerIPCCommand.parse(arguments: ["clear"] + arguments)
        case "server-list":
            return try ServerIPCCommand.parse(arguments: ["list"] + arguments)
        case "server-open":
            return try ServerIPCCommand.parse(arguments: ["open"] + arguments)
        case "server-watch-set":
            return try ServerIPCCommand.parse(arguments: ["watch-set"] + arguments)
        case "server-watch-clear":
            return try ServerIPCCommand.parse(arguments: ["watch-clear"] + arguments)
        default:
            throw AgentIPCError.unsupportedSubcommand(subcommand)
        }
    }
}
