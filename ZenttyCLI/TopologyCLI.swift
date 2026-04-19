import ArgumentParser
import Foundation

enum DiscoveryIPC {
    static func send(
        subcommand: String,
        arguments: [String] = []
    ) throws -> AgentIPCResponse? {
        let env = ProcessInfo.processInfo.environment
        guard let socketPath = env["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            throw ValidationError("Not running inside a Zentty instance.")
        }

        let request = AgentIPCRequest(
            kind: .discover,
            arguments: arguments,
            standardInput: nil,
            environment: IPCCommand.forwardedEnvironment(from: env),
            expectsResponse: true,
            subcommand: subcommand
        )
        return try AgentIPCClient.send(request: request, socketPath: socketPath)
    }
}

struct PaneTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target a specific window.")
    var windowID: String?

    @Option(name: .long, help: "Target a specific worklane.")
    var worklaneID: String?

    @Option(name: .long, help: "Target a specific pane ID.")
    var paneID: String?

    @Option(name: .long, help: "Target a specific 1-based pane index within the selected worklane.")
    var paneIndex: Int?

    @Option(name: .long, help: "Use this pane token for out-of-pane control.")
    var paneToken: String?

    var hasExplicitPaneSelector: Bool {
        paneID != nil || paneIndex != nil
    }

    var hasAnyExplicitSelector: Bool {
        windowID != nil || worklaneID != nil || paneID != nil || paneIndex != nil || paneToken != nil
    }

    func selectorArguments() -> [String] {
        var arguments: [String] = []
        if let windowID {
            arguments.append(contentsOf: ["--window-id", windowID])
        }
        if let worklaneID {
            arguments.append(contentsOf: ["--worklane-id", worklaneID])
        }
        if let paneID {
            arguments.append(contentsOf: ["--pane-id", paneID])
        }
        if let paneIndex {
            arguments.append(contentsOf: ["--pane-index", String(paneIndex)])
        }
        if let paneToken {
            arguments.append(contentsOf: ["--pane-token", paneToken])
        }
        return arguments
    }

    func validatedForPositionalPaneSelector(_ target: String?) throws {
        guard let target else {
            return
        }

        let lowered = target.lowercased()
        let isDirection = ["left", "right", "up", "down"].contains(lowered)
        let isPaneReference = !isDirection
        if isPaneReference && hasExplicitPaneSelector {
            throw ValidationError("Do not combine a positional pane target with --pane-id or --pane-index.")
        }
    }
}

struct PaneDiscoveryFilterOptions: ParsableArguments {
    @Option(name: .long, help: "Filter by window.")
    var windowID: String?

    @Option(name: .long, help: "Filter by worklane.")
    var worklaneID: String?

    @Flag(name: .long, help: "Include control tokens in JSON output.")
    var includeControlToken = false

    func arguments() -> [String] {
        var arguments: [String] = []
        if let windowID {
            arguments.append(contentsOf: ["--window-id", windowID])
        }
        if let worklaneID {
            arguments.append(contentsOf: ["--worklane-id", worklaneID])
        }
        if includeControlToken {
            arguments.append("--include-control-token")
        }
        return arguments
    }
}

struct ListCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Zentty resources.",
        subcommands: [
            ListWindowsCommand.self,
            ListWorklanesCommand.self,
            ListPanesCommand.self,
        ]
    )

    @OptionGroup var filters: PaneDiscoveryFilterOptions

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        let overview = try fetchTopologyOverview(filters: filters)
        if json {
            try printJSON(overview)
            return
        }

        renderTopologyOverview(overview)
    }
}

struct WindowCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Read window resources.",
        subcommands: [WindowListCommand.self]
    )
}

struct WorklaneCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worklane",
        abstract: "Read worklane resources.",
        subcommands: [WorklaneListCommand.self]
    )
}

struct SelectCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Resolve a resource selection.",
        subcommands: [SelectPaneCommand.self]
    )
}

struct ListWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List windows."
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        let windows = try DiscoveryIPC.send(subcommand: "windows")?.result?.discoveredWindows ?? []
        if json {
            try printJSON(windows)
            return
        }

        if windows.isEmpty {
            print("No windows.")
            return
        }

        print("\(pad("ORDER", 5))  F  \(pad("WINDOW", 36))  \(pad("WORKLANES", 9))  PANES")
        for window in windows {
            print(
                "\(pad(String(window.order), 5))  \(window.isFocused ? "*" : " ")  \(pad(window.id, 36))  \(pad(String(window.worklaneCount), 9))  \(window.paneCount)"
            )
        }
    }
}

struct WindowListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List windows."
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        var command = ListWindowsCommand()
        command.json = json
        try command.run()
    }
}

struct ListWorklanesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worklanes",
        abstract: "List worklanes."
    )

    @OptionGroup var filters: PaneDiscoveryFilterOptions

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        let worklanes = try DiscoveryIPC.send(
            subcommand: "worklanes",
            arguments: filters.arguments()
        )?.result?.discoveredWorklanes ?? []
        if json {
            try printJSON(worklanes)
            return
        }

        if worklanes.isEmpty {
            print("No worklanes.")
            return
        }

        print("\(pad("WINDOW", 36))  \(pad("ORDER", 5))  F  \(pad("WORKLANE", 20))  \(pad("TITLE", 16))  \(pad("COLS", 4))  PANES")
        for worklane in worklanes {
            print(
                "\(pad(worklane.windowID, 36))  \(pad(String(worklane.order), 5))  \(worklane.isFocused ? "*" : " ")  \(pad(worklane.id, 20))  \(pad(String((worklane.title ?? "-").prefix(16)), 16))  \(pad(String(worklane.columnCount), 4))  \(worklane.paneCount)"
            )
        }
    }
}

struct WorklaneListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List worklanes."
    )

    @OptionGroup var filters: PaneDiscoveryFilterOptions

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        var command = ListWorklanesCommand()
        command.filters = filters
        command.json = json
        try command.run()
    }
}

struct ListPanesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "panes",
        abstract: "List panes."
    )

    @OptionGroup var filters: PaneDiscoveryFilterOptions

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        try renderPanes(arguments: filters.arguments(), json: json)
    }
}

struct SelectPaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Resolve a single pane target."
    )

    @OptionGroup var target: PaneTargetOptions

    @Flag(name: .long, help: "Print shell export lines.")
    var shell = false

    @Flag(name: .long, help: "Include the pane control token.")
    var includeControlToken = false

    mutating func run() throws {
        let env = ProcessInfo.processInfo.environment
        guard let socketPath = env["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            throw ValidationError("Not running inside a Zentty instance.")
        }

        var discoveryArguments: [String] = []
        if let windowID = target.windowID ?? env["ZENTTY_WINDOW_ID"] {
            discoveryArguments.append(contentsOf: ["--window-id", windowID])
        }

        let resolvedWorklaneID = target.worklaneID ?? env["ZENTTY_WORKLANE_ID"]
        if target.paneIndex != nil || target.worklaneID != nil {
            guard let resolvedWorklaneID else {
                throw ValidationError("Pane index selection requires a worklane. Pass --worklane-id or run inside a pane.")
            }
            discoveryArguments.append(contentsOf: ["--worklane-id", resolvedWorklaneID])
        }
        if includeControlToken {
            discoveryArguments.append("--include-control-token")
        }

        let panes = try DiscoveryIPC.send(
            subcommand: "panes",
            arguments: discoveryArguments
        )?.result?.discoveredPanes ?? []

        let selectedPane: DiscoveredPane? = if let paneID = target.paneID {
            panes.first(where: { $0.id == paneID })
        } else if let paneIndex = target.paneIndex {
            panes.first(where: { $0.index == paneIndex })
        } else if let paneID = env["ZENTTY_PANE_ID"] {
            panes.first(where: { $0.id == paneID })
        } else {
            nil
        }

        guard let selectedPane else {
            throw ValidationError("Could not resolve a pane for the requested selectors.")
        }

        if shell {
            print("export ZENTTY_INSTANCE_SOCKET='\(shellEscape(socketPath))'")
            print("export ZENTTY_WINDOW_ID='\(shellEscape(selectedPane.windowID))'")
            print("export ZENTTY_WORKLANE_ID='\(shellEscape(selectedPane.worklaneID))'")
            print("export ZENTTY_PANE_ID='\(shellEscape(selectedPane.id))'")
            if includeControlToken, let controlToken = selectedPane.controlToken {
                print("export ZENTTY_PANE_TOKEN='\(shellEscape(controlToken))'")
            }
            return
        }

        print("window \(selectedPane.windowID)")
        print("worklane \(selectedPane.worklaneID)")
        print("pane \(selectedPane.id)")
    }
}

private struct TopologyOverview: Encodable {
    let windows: [TopologyWindow]

    var worklaneCount: Int {
        windows.reduce(0) { $0 + $1.worklanes.count }
    }

    var paneCount: Int {
        windows.reduce(0) { $0 + $1.paneCount }
    }
}

private struct TopologyWindow: Encodable {
    let id: String
    let order: Int
    let isFocused: Bool
    let worklanes: [TopologyWorklane]

    var paneCount: Int {
        worklanes.reduce(0) { $0 + $1.panes.count }
    }
}

private struct TopologyWorklane: Encodable {
    let id: String
    let order: Int
    let title: String?
    let isFocused: Bool
    let columnCount: Int
    let focusedPaneID: String?
    let panes: [DiscoveredPane]
}

private func fetchTopologyOverview(filters: PaneDiscoveryFilterOptions) throws -> TopologyOverview {
    let arguments = filters.arguments()
    let windows = try DiscoveryIPC.send(
        subcommand: "windows",
        arguments: arguments
    )?.result?.discoveredWindows ?? []
    let worklanes = try DiscoveryIPC.send(
        subcommand: "worklanes",
        arguments: arguments
    )?.result?.discoveredWorklanes ?? []
    let panes = try DiscoveryIPC.send(
        subcommand: "panes",
        arguments: arguments
    )?.result?.discoveredPanes ?? []

    let filteredWindows = windows.filter { window in
        if filters.worklaneID != nil {
            return worklanes.contains(where: { $0.windowID == window.id })
        }
        return true
    }

    return TopologyOverview(
        windows: filteredWindows.map { window in
            TopologyWindow(
                id: window.id,
                order: window.order,
                isFocused: window.isFocused,
                worklanes: worklanes
                    .filter { $0.windowID == window.id }
                    .map { worklane in
                        TopologyWorklane(
                            id: worklane.id,
                            order: worklane.order,
                            title: worklane.title,
                            isFocused: worklane.isFocused,
                            columnCount: worklane.columnCount,
                            focusedPaneID: worklane.focusedPaneID,
                            panes: panes
                                .filter { $0.windowID == window.id && $0.worklaneID == worklane.id }
                                .sorted { lhs, rhs in
                                    if lhs.index != rhs.index {
                                        return lhs.index < rhs.index
                                    }
                                    return lhs.column < rhs.column
                                }
                        )
                    }
                    .sorted { $0.order < $1.order }
            )
        }
    )
}

private func renderTopologyOverview(_ overview: TopologyOverview) {
    guard !overview.windows.isEmpty else {
        print("No windows.")
        return
    }

    print("WINDOWS \(overview.windows.count)  WORKLANES \(overview.worklaneCount)  PANES \(overview.paneCount)")
    print("")

    for (windowIndex, window) in overview.windows.enumerated() {
        print(
            "window \(focusMarker(window.isFocused))  \(window.order)  \(window.id)  worklanes:\(window.worklanes.count)  panes:\(window.paneCount)"
        )

        for worklane in window.worklanes {
            let titleSegment = worklane.title.map {
                "\(pad(truncateTail(displayTitle($0), 28), 28))  "
            } ?? ""
            print(
                "  worklane \(focusMarker(worklane.isFocused))  \(worklane.order)  \(titleSegment)\(worklane.id)  panes:\(worklane.panes.count)"
            )

            for pane in worklane.panes {
                let cwd = pane.workingDirectory.map(abbreviateHome).map { truncateLeading($0, 42) } ?? "-"
                let title = truncateTail(nonEmpty(pane.title), 42)
                let agentSummary = renderAgentSummary(tool: pane.agentTool, status: pane.agentStatus)
                let agentSuffix = agentSummary.map { "  \($0)" } ?? ""
                print(
                    "    pane \(focusMarker(pane.isFocused))  \(pad(String(pane.index), 2))  \(pane.id)  \(pad(title, 42))  \(cwd)\(agentSuffix)"
                )
            }
        }

        if windowIndex < overview.windows.count - 1 {
            print("")
        }
    }
}

func renderPanes(arguments: [String], json: Bool) throws {
    let panes = try DiscoveryIPC.send(
        subcommand: "panes",
        arguments: arguments
    )?.result?.discoveredPanes ?? []

    if json {
        try printJSON(panes)
        return
    }

    if panes.isEmpty {
        print("No panes.")
        return
    }

    print(
        "\(pad("WINDOW", 12))  \(pad("WORKLANE", 20))  \(pad("IDX", 3))  \(pad("COL", 3))  F  \(pad("TITLE", 16))  \(pad("CWD", 30))  \(pad("AGENT", 12))  STATUS"
    )
    for pane in panes {
        let cwd = pane.workingDirectory.map(abbreviateHome) ?? "-"
        let agent = pane.agentTool ?? "-"
        let status = pane.agentStatus ?? "-"
        print(
            "\(pad(String(pane.windowID.prefix(12)), 12))  \(pad(String(pane.worklaneID.prefix(20)), 20))  \(pad(String(pane.index), 3))  \(pad(String(pane.column), 3))  \(pane.isFocused ? "*" : " ")  \(pad(String(pane.title.prefix(16)), 16))  \(pad(String(cwd.prefix(30)), 30))  \(pad(String(agent.prefix(12)), 12))  \(status)"
        )
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "")
}

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func abbreviateHome(_ path: String) -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    guard !home.isEmpty, path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
}

func abbreviateIdentifier(_ value: String, visibleCount: Int = 12) -> String {
    value.count <= visibleCount ? value : String(value.prefix(visibleCount))
}

func truncateTail(_ value: String, _ limit: Int) -> String {
    guard value.count > limit, limit > 1 else { return value }
    return String(value.prefix(limit - 1)) + "…"
}

func truncateLeading(_ value: String, _ limit: Int) -> String {
    guard value.count > limit, limit > 1 else { return value }
    return "…" + String(value.suffix(limit - 1))
}

func focusMarker(_ isFocused: Bool) -> String {
    isFocused ? "*" : " "
}

func displayTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled" : trimmed
}

func nonEmpty(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "-" : trimmed
}

func renderAgentSummary(tool: String?, status: String?) -> String? {
    let parts = [tool, status].compactMap { value -> String? in
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return truncateTail(value, 14)
    }
    guard !parts.isEmpty else {
        return nil
    }
    return "[\(parts.joined(separator: " "))]"
}

func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\"'\"'")
}
