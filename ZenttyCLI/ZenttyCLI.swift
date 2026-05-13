import ArgumentParser
import Darwin
import Foundation
import os

private let ipcCLILogger = Logger(subsystem: "be.zenjoy.zentty", category: "IPC")

@main
struct ZenttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zentty",
        abstract: "Zentty command-line interface.",
        subcommands: [
            VersionCommand.self,
            ListCommandGroup.self,
            WindowCommandGroup.self,
            WorklaneCommandGroup.self,
            SelectCommandGroup.self,
            SplitCommand.self,
            HSplitCommand.self,
            VSplitCommand.self,
            GridCommand.self,
            PaneCommandGroup.self,
            LayoutCommand.self,
            NotifyCommand.self,
            CodexNotifyCommand.self,
            GeminiHookCommand.self,
            IPCCommand.self,
            LaunchCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            TmuxCompatCommand.self,
        ]
    )
}

// MARK: - install / uninstall

private enum IntegrationTarget: String, CaseIterable {
    case cursorHooks = "cursor-hooks"
    case kimiHooks = "kimi-hooks"

    static func resolve(_ raw: String) throws -> IntegrationTarget {
        guard let target = IntegrationTarget(rawValue: raw) else {
            let supported = IntegrationTarget.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown target '\(raw)'. Supported: \(supported)")
        }
        return target
    }
}

private func resolveInvokingCLIPath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0 else {
        return CommandLine.arguments[0]
    }
    var buffer = [CChar](repeating: 0, count: Int(size))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        _NSGetExecutablePath(pointer.baseAddress, &size)
    }
    guard result == 0 else {
        return CommandLine.arguments[0]
    }
    return URL(fileURLWithPath: String(cString: buffer))
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a Zentty agent integration.",
        discussion: "Supported targets: \(IntegrationTarget.allCases.map(\.rawValue).joined(separator: ", "))"
    )

    @Argument(help: "Target integration name (e.g. cursor-hooks, kimi-hooks).")
    var target: String

    mutating func run() throws {
        switch try IntegrationTarget.resolve(target) {
        case .cursorHooks:
            let hooksURL = CursorHooksInstaller.defaultUserHooksURL()
            try CursorHooksInstaller.install(
                at: hooksURL,
                cliPath: resolveInvokingCLIPath()
            )
            print("Installed Zentty cursor hooks at \(hooksURL.path).")
        case .kimiHooks:
            let configURL = KimiHooksInstaller.defaultUserConfigURL()
            try KimiHooksInstaller.install(
                at: configURL,
                cliPath: resolveInvokingCLIPath()
            )
            print("Installed Zentty Kimi hooks at \(configURL.path).")
        }
    }
}

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove a previously-installed Zentty agent integration.",
        discussion: "Supported targets: \(IntegrationTarget.allCases.map(\.rawValue).joined(separator: ", "))"
    )

    @Argument(help: "Target integration name (e.g. cursor-hooks, kimi-hooks).")
    var target: String

    mutating func run() throws {
        switch try IntegrationTarget.resolve(target) {
        case .cursorHooks:
            let hooksURL = CursorHooksInstaller.defaultUserHooksURL()
            try CursorHooksInstaller.uninstall(at: hooksURL)
            print("Removed Zentty cursor hook entries from \(hooksURL.path).")
        case .kimiHooks:
            let configURL = KimiHooksInstaller.defaultUserConfigURL()
            try KimiHooksInstaller.uninstall(at: configURL)
            print("Removed Zentty Kimi hook entries from \(configURL.path).")
        }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show the running Zentty version."
    )

    mutating func run() throws {
        let metadata = ZenttyVersionMetadata.load()
        print("zentty \(metadata.version) (\(metadata.commit))")
    }
}

// MARK: - Pane IPC Helpers

private enum PaneIPC {
    static func send(
        subcommand: String,
        arguments: [String] = [],
        expectsResponse: Bool = true
    ) throws -> AgentIPCResponse? {
        let env = ProcessInfo.processInfo.environment
        guard let socketPath = env["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            throw ValidationError("Not running inside a Zentty instance.")
        }

        let request = AgentIPCRequest(
            kind: .pane,
            arguments: arguments,
            standardInput: nil,
            environment: IPCCommand.forwardedEnvironment(from: env),
            expectsResponse: expectsResponse,
            subcommand: subcommand
        )
        return try AgentIPCClient.send(request: request, socketPath: socketPath)
    }
}

// MARK: - Split Commands

struct SplitLayoutOptions: ParsableArguments {
    @Flag(name: .long, help: "Split into equal halves.")
    var equal = false

    @Flag(name: .long, help: "Split using golden ratio (focused pane gets ~62%).")
    var golden = false

    @Option(name: .long, help: "Set the focused pane to this percentage (e.g. 60).")
    var ratio: Int?

    func layoutArguments() -> [String] {
        if equal { return ["--equal"] }
        if golden { return ["--golden"] }
        if let ratio { return ["--ratio", String(ratio)] }
        return []
    }
}

struct SplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split the focused pane."
    )

    @Argument(help: "Direction: right (default), left, up, down.")
    var direction: String = "right"

    @OptionGroup var layout: SplitLayoutOptions
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        let validDirections = ["right", "left", "up", "down"]
        guard validDirections.contains(direction) else {
            throw ValidationError("Invalid direction '\(direction)'. Use: \(validDirections.joined(separator: ", "))")
        }
        _ = try PaneIPC.send(
            subcommand: "split",
            arguments: [direction] + layout.layoutArguments() + target.selectorArguments()
        )
    }
}

struct HSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hsplit",
        abstract: "Split horizontally (alias for 'split right')."
    )

    @OptionGroup var layout: SplitLayoutOptions
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(
            subcommand: "split",
            arguments: ["right"] + layout.layoutArguments() + target.selectorArguments()
        )
    }
}

struct VSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vsplit",
        abstract: "Split vertically (alias for 'split down')."
    )

    @OptionGroup var layout: SplitLayoutOptions
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(
            subcommand: "split",
            arguments: ["down"] + layout.layoutArguments() + target.selectorArguments()
        )
    }
}

struct GridCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grid",
        abstract: "Turn the focused pane into a rows-by-columns grid."
    )

    @Argument(
        parsing: .captureForPassthrough,
        help: "Use ROWSxCOLUMNS [--include-source] [--focus source|first|last] [-- command ...]."
    )
    var rawArguments: [String] = []

    mutating func run() throws {
        if shouldPrintHelp {
            print(Self.helpText)
            return
        }

        let invocation = try parseInvocation()
        let dimensions = try parseDimensions(invocation.rowsOrGrid)
        guard dimensions.rows * dimensions.columns <= 36 else {
            throw ValidationError("Grid dimensions may create at most 36 panes.")
        }
        guard ["source", "first", "last"].contains(invocation.focus) else {
            throw ValidationError("Invalid focus '\(invocation.focus)'. Use: source, first, last.")
        }

        var arguments = [
            "--rows", String(dimensions.rows),
            "--columns", String(dimensions.columns),
        ]
        if !invocation.includeSource {
            arguments.append("--new-only")
        }
        arguments.append(contentsOf: ["--focus", invocation.focus])
        arguments.append(contentsOf: invocation.destinationArguments)

        if !invocation.command.isEmpty {
            let data = try JSONEncoder().encode(invocation.command)
            guard let json = String(data: data, encoding: .utf8) else {
                throw ValidationError("Unable to encode grid command.")
            }
            arguments.append(contentsOf: ["--command-json", json])
        }

        _ = try PaneIPC.send(
            subcommand: "grid",
            arguments: arguments + invocation.targetArguments
        )
    }

    private var shouldPrintHelp: Bool {
        let gridArguments = rawArguments.prefix { $0 != "--" }
        return gridArguments.contains("--help") || gridArguments.contains("-h")
    }

    private static let helpText = """
    OVERVIEW: Turn the focused pane into a rows-by-columns grid.

    USAGE: zentty grid <ROWSxCOLUMNS> [--new-only] [--focus <focus>] [--window-id <window-id|new>] [--worklane-id <worklane-id|new>] [--pane-id <pane-id>] [--pane-index <pane-index>] [--pane-token <pane-token>] [-- <command> ...]

    ARGUMENTS:
      <ROWSxCOLUMNS>          Grid size, for example 2x3.
      <command>               Optional command to run in each grid pane.

    OPTIONS:
      --new-only              Run the command only in newly-created panes.
      --include-source        Run the command in the source pane too. This is the default.
      --focus <focus>         Pane to focus after creating the grid: source, first, or last. (default: source)
      --window-id <window-id|new>
                              Target a specific window, or use 'new' to create a new window.
      --worklane-id <worklane-id|new>
                              Target a specific worklane, or use 'new' to create a new worklane.
      --pane-id <pane-id>     Target a specific pane ID.
      --pane-index <pane-index>
                              Target a specific 1-based pane index within the selected worklane.
      --pane-token <pane-token>
                              Use this pane token for out-of-pane control.
      -h, --help              Show help information.
    """

    private struct Invocation {
        var rowsOrGrid: String
        var includeSource: Bool
        var focus: String
        var targetArguments: [String]
        var destinationArguments: [String]
        var command: [String]
    }

    private func parseInvocation() throws -> Invocation {
        var rowsOrGrid: String?
        var includeSource = true
        var focus = "source"
        var targetArguments: [String] = []
        var destinationArguments: [String] = []
        var destinationWindowIsNew = false
        var hasExistingWorklaneSelector = false
        var index = 0

        while index < rawArguments.count {
            let argument = rawArguments[index]
            if argument == "--" {
                return try makeInvocation(
                    rowsOrGrid: requireRowsOrGrid(rowsOrGrid),
                    includeSource: includeSource,
                    focus: focus,
                    targetArguments: targetArguments,
                    destinationArguments: destinationArguments,
                    destinationWindowIsNew: destinationWindowIsNew,
                    hasExistingWorklaneSelector: hasExistingWorklaneSelector,
                    command: Array(rawArguments[(index + 1)...])
                )
            }

            if argument == "--include-source" {
                includeSource = true
                index += 1
                continue
            }
            if argument == "--new-only" {
                includeSource = false
                index += 1
                continue
            }

            if let value = optionValue(argument, prefix: "--focus=") {
                focus = value
                index += 1
                continue
            }
            if argument == "--focus" {
                focus = try value(after: argument, at: &index)
                continue
            }

            if let parsedTarget = try parseTargetOption(argument, index: &index) {
                targetArguments.append(contentsOf: parsedTarget.selectorArguments)
                destinationArguments.append(contentsOf: parsedTarget.destinationArguments)
                destinationWindowIsNew = destinationWindowIsNew || parsedTarget.createsNewWindow
                hasExistingWorklaneSelector = hasExistingWorklaneSelector || parsedTarget.usesExistingWorklane
                continue
            }

            if argument.hasPrefix("-") {
                throw ValidationError("Unknown grid option '\(argument)'.")
            }

            guard rowsOrGrid == nil else {
                throw ValidationError("Unexpected grid argument '\(argument)'. Use '--' before a command to run.")
            }
            rowsOrGrid = argument
            index += 1
        }

        return try makeInvocation(
            rowsOrGrid: requireRowsOrGrid(rowsOrGrid),
            includeSource: includeSource,
            focus: focus,
            targetArguments: targetArguments,
            destinationArguments: destinationArguments,
            destinationWindowIsNew: destinationWindowIsNew,
            hasExistingWorklaneSelector: hasExistingWorklaneSelector,
            command: []
        )
    }

    private struct ParsedTargetOption {
        var selectorArguments: [String]
        var destinationArguments: [String]
        var createsNewWindow: Bool
        var usesExistingWorklane: Bool
    }

    private func parseTargetOption(_ argument: String, index: inout Int) throws -> ParsedTargetOption? {
        let valueOptions = [
            "--window-id",
            "--worklane-id",
            "--pane-id",
            "--pane-index",
            "--pane-token",
        ]

        for option in valueOptions {
            if let value = optionValue(argument, prefix: "\(option)=") {
                try validateTargetValue(value, option: option)
                index += 1
                return parsedTargetOption(option: option, value: value)
            }
            if argument == option {
                let value = try value(after: argument, at: &index)
                try validateTargetValue(value, option: option)
                return parsedTargetOption(option: option, value: value)
            }
        }
        return nil
    }

    private func parsedTargetOption(option: String, value: String) -> ParsedTargetOption {
        if option == "--window-id", value == "new" {
            return ParsedTargetOption(
                selectorArguments: [],
                destinationArguments: ["--new-window"],
                createsNewWindow: true,
                usesExistingWorklane: false
            )
        }
        if option == "--worklane-id", value == "new" {
            return ParsedTargetOption(
                selectorArguments: [],
                destinationArguments: ["--new-worklane"],
                createsNewWindow: false,
                usesExistingWorklane: false
            )
        }
        return ParsedTargetOption(
            selectorArguments: [option, value],
            destinationArguments: [],
            createsNewWindow: false,
            usesExistingWorklane: option == "--worklane-id"
        )
    }

    private func makeInvocation(
        rowsOrGrid: String,
        includeSource: Bool,
        focus: String,
        targetArguments: [String],
        destinationArguments: [String],
        destinationWindowIsNew: Bool,
        hasExistingWorklaneSelector: Bool,
        command: [String]
    ) throws -> Invocation {
        if destinationWindowIsNew, hasExistingWorklaneSelector {
            throw ValidationError("--window-id new cannot be combined with an existing --worklane-id. Use --worklane-id new or omit --worklane-id.")
        }
        return Invocation(
            rowsOrGrid: rowsOrGrid,
            includeSource: includeSource,
            focus: focus,
            targetArguments: targetArguments,
            destinationArguments: destinationArguments,
            command: command
        )
    }

    private func value(after option: String, at index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < rawArguments.count, rawArguments[valueIndex] != "--" else {
            throw ValidationError("Missing value for \(option).")
        }
        index += 2
        return rawArguments[valueIndex]
    }

    private func validateTargetValue(_ value: String, option: String) throws {
        guard !value.isEmpty else {
            throw ValidationError("Missing value for \(option).")
        }
        if option == "--pane-index", Int(value) == nil {
            throw ValidationError("--pane-index must be an integer.")
        }
    }

    private func optionValue(_ argument: String, prefix: String) -> String? {
        guard argument.hasPrefix(prefix) else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }

    private func requireRowsOrGrid(_ rowsOrGrid: String?) throws -> String {
        guard let rowsOrGrid else {
            throw ValidationError("Grid size must be ROWSxCOLUMNS, for example 2x3.")
        }
        return rowsOrGrid
    }

    private func parseDimensions(_ rowsOrGrid: String) throws -> (rows: Int, columns: Int) {
        let parts = rowsOrGrid.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let rows = Int(parts[0]),
              let columns = Int(parts[1]),
              rows > 0,
              columns > 0 else {
            throw ValidationError("Grid size must be ROWSxCOLUMNS, for example 2x3.")
        }
        return (rows, columns)
    }
}

// MARK: - Pane Commands

struct PaneCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pane",
        abstract: "Manage panes.",
        subcommands: [
            PaneListCommand.self,
            PaneFocusCommand.self,
            PaneCloseCommand.self,
            PaneZoomCommand.self,
            PaneResizeCommand.self,
        ]
    )
}

struct PaneListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all panes in the current worklane."
    )

    @OptionGroup var filters: PaneDiscoveryFilterOptions

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        var arguments = filters.arguments()
        let environment = ProcessInfo.processInfo.environment
        if filters.windowID == nil, filters.worklaneID == nil,
           let worklaneID = environment["ZENTTY_WORKLANE_ID"] {
            if let windowID = environment["ZENTTY_WINDOW_ID"] {
                arguments.append(contentsOf: ["--window-id", windowID])
            }
            arguments.append(contentsOf: ["--worklane-id", worklaneID])
        }
        try renderPanes(arguments: arguments, json: json)
    }
}

struct PaneFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a pane by index, ID, or direction."
    )

    @Argument(help: "Pane index (1-based), pane ID, or direction (left/right/up/down).")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try selection.validatedForPositionalPaneSelector(target)
        var arguments: [String] = []
        if let target {
            arguments.append(target)
        }
        arguments += selection.selectorArguments()
        _ = try PaneIPC.send(subcommand: "focus", arguments: arguments)
    }
}

struct PaneCloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pane."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try selection.validatedForPositionalPaneSelector(target)
        var args: [String] = []
        if let target {
            args.append(target)
        }
        args += selection.selectorArguments()
        _ = try PaneIPC.send(subcommand: "close", arguments: args)
    }
}

struct WorklaneColorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "Set or reset the sidebar color of a worklane.",
        discussion: "Colors: \(WorklaneColor.allCases.map(\.rawValue).joined(separator: ", ")). Use 'reset' or 'default' to clear."
    )

    @Argument(help: "Color name, 'reset', or 'default'. Omit when using --list.")
    var value: String?

    @Option(help: "Target a specific worklane (defaults to the calling pane's worklane).")
    var id: String?

    @Flag(help: "List all available color names and exit.")
    var list: Bool = false

    mutating func run() throws {
        if list {
            for color in WorklaneColor.allCases {
                print(color.rawValue)
            }
            return
        }
        guard let raw = value else {
            throw ValidationError("Missing color. Provide a color name, 'reset', or use --list.")
        }
        let payload: String
        if raw == "reset" || raw == "default" {
            payload = "reset"
        } else if WorklaneColor(rawValue: raw) != nil {
            payload = raw
        } else {
            let supported = WorklaneColor.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown color '\(raw)'. Supported: \(supported), reset, default.")
        }
        var arguments = ["--color", payload]
        if let id {
            arguments.append(contentsOf: ["--id", id])
        }
        _ = try PaneIPC.send(subcommand: "worklane-color", arguments: arguments)
    }
}

struct PaneZoomCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zoom",
        abstract: "Toggle zoomed-out pane view."
    )

    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "zoom", arguments: target.selectorArguments())
    }
}

struct PaneResizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "Resize the focused pane."
    )

    @Argument(help: "Direction (left/right/up/down) or percentage (e.g. 60%).")
    var target: String

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(
            subcommand: "resize",
            arguments: [target] + selection.selectorArguments()
        )
    }
}

// MARK: - Layout Commands

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Apply a layout preset."
    )

    @Argument(help: "Preset: full, halves, thirds, quarters, golden-wide, golden-narrow, golden-tall, golden-short, reset.")
    var preset: String

    @Flag(name: [.short, .long], help: "Apply vertically (panes per column) instead of horizontally (columns).")
    var vertical = false

    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        var args = [preset]
        if vertical {
            args.append("--vertical")
        }
        args += target.selectorArguments()
        _ = try PaneIPC.send(subcommand: "layout", arguments: args)
    }
}

// MARK: - Notification Commands

struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Send a pane-local Zentty notification."
    )

    @Option(name: .long, help: "Notification title.")
    var title: String

    @Option(name: .long, help: "Optional notification subtitle.")
    var subtitle: String?

    @Option(name: .long, help: "Optional notification body.")
    var body: String?

    @Flag(name: .long, help: "Do not add the notification to Zentty's inbox.")
    var noInbox = false

    @Flag(name: .long, help: "Suppress the notification sound.")
    var silent = false

    mutating func run() throws {
        let environment = ProcessInfo.processInfo.environment
        guard trimmed(environment["ZENTTY_INSTANCE_SOCKET"]) != nil,
              IPCCommand.hasRequiredRoutingEnvironment(environment) else {
            throw ValidationError("Not running inside a Zentty pane.")
        }

        guard let title = trimmed(title) else {
            throw ValidationError("Missing notification title.")
        }
        let subtitle = trimmed(subtitle)
        let body = trimmed(body)

        var arguments = ["--title", title]
        if let subtitle {
            arguments.append(contentsOf: ["--subtitle", subtitle])
        }
        if let body {
            arguments.append(contentsOf: ["--body", body])
        }
        if noInbox {
            arguments.append("--no-inbox")
        }
        if silent {
            arguments.append("--silent")
        }

        _ = try PaneIPC.send(subcommand: "notify", arguments: arguments)
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

// MARK: - Agent Commands

struct CodexNotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-notify",
        abstract: "Forward a Codex notify callback payload to the running Zentty app.",
        shouldDisplay: false
    )

    @Argument(help: "The raw JSON payload passed by Codex notify callbacks.")
    var payload: String?

    mutating func run() throws {
        guard let socketPath = ProcessInfo.processInfo.environment["ZENTTY_INSTANCE_SOCKET"],
              !socketPath.isEmpty,
              IPCCommand.hasRequiredRoutingEnvironment(ProcessInfo.processInfo.environment) else {
            return
        }

        guard let payload = payload ?? standardInputPayload() else {
            throw ValidationError("Missing Codex notify payload.")
        }

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: ["--adapter=codex-notify"],
            standardInput: payload,
            environment: IPCCommand.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: false,
            subcommand: "agent-event"
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
        } catch {
            guard ProcessInfo.processInfo.environment["ZENTTY_CLI_DEBUG"] == "1" else {
                return
            }
            FileHandle.standardError.write(Data(("zentty codex-notify send failed: \(error.localizedDescription)\n").utf8))
        }
    }

    private func standardInputPayload() -> String? { readStandardInputPayload() }
}

struct GeminiHookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gemini-hook",
        abstract: "Forward a Gemini hook payload to the running Zentty app.",
        shouldDisplay: false
    )

    @Argument(help: "The raw JSON payload passed by Gemini hook callbacks.")
    var payload: String?

    mutating func run() throws {
        guard let payload = payload ?? readStandardInputPayload() else {
            throw ValidationError("Missing Gemini hook payload.")
        }

        guard let socketPath = ProcessInfo.processInfo.environment["ZENTTY_INSTANCE_SOCKET"],
              !socketPath.isEmpty,
              IPCCommand.hasRequiredRoutingEnvironment(ProcessInfo.processInfo.environment) else {
            print("{}")
            return
        }

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: ["--adapter=gemini"],
            standardInput: payload,
            environment: IPCCommand.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: false,
            subcommand: "agent-event"
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
        } catch {
            guard ProcessInfo.processInfo.environment["ZENTTY_CLI_DEBUG"] == "1" else {
                print("{}")
                return
            }
            FileHandle.standardError.write(Data(("zentty gemini-hook send failed: \(error.localizedDescription)\n").utf8))
        }

        print("{}")
    }
}

struct IPCCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipc",
        abstract: "Send agent events and signals to the running Zentty app.",
        shouldDisplay: false
    )

    private static let supportedSubcommands = Set(["agent-event", "agent-signal", "agent-status"])
    private static let forwardedEnvironmentKeys = [
        "ZENTTY_WINDOW_ID",
        "ZENTTY_WORKLANE_ID",
        "ZENTTY_PANE_ID",
        "ZENTTY_PANE_TOKEN",
        "ZENTTY_INSTANCE_ID",
        "ZENTTY_CLAUDE_PID",
        "ZENTTY_CODEX_PID",
        "ZENTTY_COPILOT_PID",
        "ZENTTY_GEMINI_PID",
        "ZENTTY_CURSOR_PID",
        "ZENTTY_DROID_PID",
        "ZENTTY_KIMI_PID",
    ]

    @Argument(help: "Supported values: agent-event, agent-signal, agent-status")
    var subcommand: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the IPC subcommand.")
    var arguments: [String] = []

    mutating func run() throws {
        let localSubcommand = subcommand
        let localArguments = arguments
        guard Self.supportedSubcommands.contains(localSubcommand) else {
            throw ValidationError("Unsupported ipc subcommand: \(localSubcommand)")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            ipcCLILogger.info("ipc \(localSubcommand, privacy: .public): skipping — ZENTTY_INSTANCE_SOCKET is not set")
            return
        }
        guard Self.hasRequiredRoutingEnvironment(environment) else {
            let missing = Self.missingRoutingEnvironmentKeys(environment).joined(separator: ",")
            ipcCLILogger.info("ipc \(localSubcommand, privacy: .public): skipping — missing \(missing, privacy: .public)")
            return
        }

        let stdinPayload = standardInput()
        let stdinLength = stdinPayload?.utf8.count ?? 0
        let stdinAttached = isatty(STDIN_FILENO) == 0
        ipcCLILogger.debug("ipc \(localSubcommand, privacy: .public) reading stdin: attached=\(stdinAttached, privacy: .public) bytes=\(stdinLength)")

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: localArguments,
            standardInput: stdinPayload,
            environment: Self.forwardedEnvironment(from: environment),
            expectsResponse: false,
            subcommand: localSubcommand
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
            ipcCLILogger.debug("ipc \(localSubcommand, privacy: .public) sent (args: \(localArguments.joined(separator: " "), privacy: .private))")
        } catch {
            ipcCLILogger.error("ipc \(localSubcommand, privacy: .public) send failed: \(error.localizedDescription, privacy: .private)")
            guard environment["ZENTTY_CLI_DEBUG"] == "1" else {
                return
            }
            FileHandle.standardError.write(Data(("zentty ipc send failed: \(error.localizedDescription)\n").utf8))
        }
    }

    private func standardInput() -> String? {
        guard subcommand == "agent-event", isatty(STDIN_FILENO) == 0 else {
            return nil
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func hasRequiredRoutingEnvironment(_ environment: [String: String]) -> Bool {
        missingRoutingEnvironmentKeys(environment).isEmpty
    }

    static func missingRoutingEnvironmentKeys(_ environment: [String: String]) -> [String] {
        ["ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"].filter { key in
            (environment[key] ?? "").isEmpty
        }
    }

    static func forwardedEnvironment(from environment: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.forwardedEnvironmentKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else {
                return nil
            }
            return (key, value)
        })
    }
}

struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Prepare and launch an integrated tool inside Zentty.",
        shouldDisplay: false
    )

    @Argument(help: "Supported values: claude, codex, copilot, cursor, gemini, kimi, opencode, pi")
    var tool: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the real tool.")
    var arguments: [String] = []

    mutating func run() throws {
        guard let tool = AgentBootstrapTool(rawValue: tool) else {
            throw ValidationError("Unsupported launch tool: \(tool)")
        }
        try AgentToolLauncher(tool: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment).run()
    }
}

private func readStandardInputPayload() -> String? {
    guard isatty(STDIN_FILENO) == 0 else {
        return nil
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

private struct ZenttyVersionMetadata {
    let version: String
    let commit: String

    static func load(
        currentBundle: Bundle = .main,
        executableURL: URL = resolvedExecutableURL(),
        fileManager: FileManager = .default
    ) -> ZenttyVersionMetadata {
        for candidateURL in candidateBundleURLs(
            for: executableURL,
            currentBundle: currentBundle,
            fileManager: fileManager
        ) {
            guard let candidateBundle = Bundle(url: candidateURL) else {
                continue
            }
            let metadata = from(bundle: candidateBundle)
            if metadata.version != "Unknown" || metadata.commit != "unknown" {
                return metadata
            }
        }

        return from(bundle: currentBundle)
    }

    private static func from(bundle: Bundle) -> ZenttyVersionMetadata {
        let infoDictionary = bundle.infoDictionary ?? [:]
        return ZenttyVersionMetadata(
            version: trimmedValue(for: "CFBundleShortVersionString", in: infoDictionary) ?? "Unknown",
            commit: trimmedValue(for: "ZenttyGitCommit", in: infoDictionary) ?? "unknown"
        )
    }

    private static func candidateBundleURLs(
        for executableURL: URL,
        currentBundle: Bundle,
        fileManager: FileManager
    ) -> [URL] {
        var bundleURLs: [URL] = []
        let standardizedExecutableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        let pathComponents = standardizedExecutableURL.pathComponents

        if let appIndex = pathComponents.lastIndex(where: { $0.hasSuffix(".app") }) {
            let appURL = pathComponents[0...appIndex].reduce(URL(fileURLWithPath: "/")) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            bundleURLs.append(appURL)
        }

        let siblingAppURL = standardizedExecutableURL
            .deletingLastPathComponent()
            .appendingPathComponent("Zentty.app", isDirectory: true)
        if fileManager.fileExists(atPath: siblingAppURL.path) {
            bundleURLs.append(siblingAppURL)
        }

        let currentBundleURL = currentBundle.bundleURL.standardizedFileURL
        if fileManager.fileExists(atPath: currentBundleURL.path) {
            bundleURLs.append(currentBundleURL)
        }

        var deduplicated: [URL] = []
        var seenPaths = Set<String>()
        for url in bundleURLs {
            if seenPaths.insert(url.path).inserted {
                deduplicated.append(url)
            }
        }
        return deduplicated
    }

    private static func trimmedValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let rawValue = infoDictionary[key] as? String else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resolvedExecutableURL() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }

        let executablePath = String(cString: buffer)
        return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
    }
}
