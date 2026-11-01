import Foundation

/// `zentty pane float|dock|pip|minimize|restore` and `zentty float
/// new|list|hide|show` (wire contract in `FloatControlProtocol.swift`).
/// `target` is the calling (or selected) pane; a positional pane reference
/// resolves in its worklane, with the `pane list` numbering.
@MainActor
enum FloatIPCHandler {
    static func handle(
        _ subcommand: PaneIPCSubcommand,
        request: AgentIPCRequest,
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) throws -> AgentIPCResponseResult {
        if let action = subcommand.floatAction {
            let options = try PaneFloatIPCOptions.parse(arguments: request.arguments, action: action)
            let paneID = try resolve(options.target, target: target, windowController: windowController)
            try windowController.applyFloatAction(
                action,
                to: paneID,
                corner: options.corner.flatMap(FloatCorner.init(wireName:))
            )
            return AgentIPCResponseResult()
        }

        switch subcommand {
        case .floatNew:
            let options = try FloatNewIPCOptions.parse(arguments: request.arguments)
            let command = options.command.isEmpty ? nil : try GridLaunchCommandBuilder.command(from: options.command)
            let paneID = try windowController.openFloat(
                from: target.paneID,
                workingDirectory: options.workingDirectory,
                command: command,
                temporary: options.temporary
            )
            return AgentIPCResponseResult(stdout: "\(paneID.rawValue)\n")
        case .floatList:
            try FloatWorklaneIPCOptions.validate(arguments: request.arguments)
            return AgentIPCResponseResult(floatList: windowController.floatListEntries(in: target.worklaneID))
        case .floatHide, .floatShow:
            try FloatWorklaneIPCOptions.validate(arguments: request.arguments)
            try windowController.setFloatsHidden(subcommand == .floatHide, in: target.worklaneID)
            return AgentIPCResponseResult()
        default:
            throw AgentIPCError.unsupportedSubcommand(subcommand.rawValue)
        }
    }

    private static func resolve(
        _ reference: String?,
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) throws -> PaneID {
        guard let reference else {
            return target.paneID
        }
        let normalized = reference.hasPrefix("%") ? String(reference.dropFirst()) : reference
        guard let paneID = windowController.resolvePaneID(normalized, in: target.worklaneID) else {
            throw PaneRoutingError.paneNotFound
        }
        return paneID
    }
}
