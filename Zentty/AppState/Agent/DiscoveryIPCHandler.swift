import AppKit
import Foundation

private enum DiscoveryIPCSubcommand: String {
    case windows
    case worklanes
    case panes
}

private struct DiscoveryIPCOptions {
    let windowID: WindowID?
    let worklaneID: WorklaneID?
    let includeControlToken: Bool

    static func parse(arguments: [String]) throws -> DiscoveryIPCOptions {
        var windowID: WindowID?
        var worklaneID: WorklaneID?
        var includeControlToken = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--window-id":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneRoutingError.missingValue(argument)
                }
                windowID = WindowID(arguments[valueIndex])
                index += 2
            case "--worklane-id":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneRoutingError.missingValue(argument)
                }
                worklaneID = WorklaneID(arguments[valueIndex])
                index += 2
            case "--include-control-token":
                includeControlToken = true
                index += 1
            default:
                throw AgentIPCError.unsupportedSubcommand(argument)
            }
        }

        return DiscoveryIPCOptions(
            windowID: windowID,
            worklaneID: worklaneID,
            includeControlToken: includeControlToken
        )
    }
}

enum DiscoveryIPCHandler {
    static func handle(request: AgentIPCRequest) throws -> AgentIPCResponseResult {
        guard let subcommandRaw = request.subcommand,
              let subcommand = DiscoveryIPCSubcommand(rawValue: subcommandRaw) else {
            throw AgentIPCError.unsupportedSubcommand(request.subcommand ?? "<nil>")
        }

        let options = try DiscoveryIPCOptions.parse(arguments: request.arguments)

        var result: Result<AgentIPCResponseResult, Error>!
        let resolve = {
            result = .success(MainActor.assumeIsolated {
                self.dispatch(subcommand: subcommand, options: options)
            })
        }
        if Thread.isMainThread {
            resolve()
        } else {
            DispatchQueue.main.sync(execute: resolve)
        }
        return try result.get()
    }

    @MainActor
    private static func dispatch(
        subcommand: DiscoveryIPCSubcommand,
        options: DiscoveryIPCOptions
    ) -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            return AgentIPCResponseResult()
        }

        let controllers = appDelegate.orderedWindowControllersForDiscovery().filter { controller in
            options.windowID.map { controller.windowID == $0 } ?? true
        }

        let windows = controllers.map { controller -> DiscoveredWindow in
            let workspaceState = controller.discoveryWorkspaceState
            return DiscoveredWindow(
                id: controller.windowID.rawValue,
                order: controller.windowOrder + 1,
                isFocused: controller.window.isKeyWindow,
                worklaneCount: workspaceState.worklanes.count,
                paneCount: workspaceState.worklanes.reduce(0) { partialResult, worklane in
                    partialResult + worklane.paneStripState.panes.count
                }
            )
        }

        let worklanes = controllers.flatMap { controller -> [DiscoveredWorklane] in
            let workspaceState = controller.discoveryWorkspaceState
            return workspaceState.worklanes.enumerated().compactMap { order, worklane in
                if let requestedWorklaneID = options.worklaneID, worklane.id != requestedWorklaneID {
                    return nil
                }

                return DiscoveredWorklane(
                    id: worklane.id.rawValue,
                    windowID: controller.windowID.rawValue,
                    order: order + 1,
                    title: worklane.meaningfulTitle,
                    isFocused: workspaceState.activeWorklaneID == worklane.id,
                    paneCount: worklane.paneStripState.panes.count,
                    columnCount: worklane.paneStripState.columns.count,
                    focusedPaneID: worklane.paneStripState.focusedPaneID?.rawValue
                )
            }
        }

        let panes = controllers.flatMap { controller -> [DiscoveredPane] in
            let workspaceState = controller.discoveryWorkspaceState
            return workspaceState.worklanes.flatMap { worklane -> [DiscoveredPane] in
                if let requestedWorklaneID = options.worklaneID, worklane.id != requestedWorklaneID {
                    return []
                }

                return controller.paneListEntries(for: worklane.id).map { pane -> DiscoveredPane in
                    DiscoveredPane(
                        id: pane.id,
                        windowID: controller.windowID.rawValue,
                        worklaneID: worklane.id.rawValue,
                        index: pane.index,
                        column: pane.column,
                        title: pane.title,
                        workingDirectory: pane.workingDirectory,
                        isFocused: pane.isFocused,
                        agentTool: pane.agentTool,
                        agentStatus: pane.agentStatus,
                        controlToken: options.includeControlToken
                            ? AgentIPCServer.shared.paneToken(
                                windowID: controller.windowID,
                                worklaneID: worklane.id,
                                paneID: PaneID(pane.id)
                            )
                            : nil
                    )
                }
            }
        }

        switch subcommand {
        case .windows:
            return AgentIPCResponseResult(discoveredWindows: windows)
        case .worklanes:
            return AgentIPCResponseResult(discoveredWorklanes: worklanes)
        case .panes:
            return AgentIPCResponseResult(discoveredPanes: panes)
        }
    }
}
