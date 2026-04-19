import ArgumentParser
import Darwin
import Foundation

@main
struct ZenttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zentty",
        abstract: "Zentty command-line interface.",
        subcommands: [
            VersionCommand.self,
            SplitCommand.self,
            HSplitCommand.self,
            VSplitCommand.self,
            PaneCommandGroup.self,
            LayoutCommand.self,
            CodexNotifyCommand.self,
            GeminiHookCommand.self,
            IPCCommand.self,
            LaunchCommand.self,
        ]
    )
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
        guard let socketPath = env["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty,
              IPCCommand.hasRequiredRoutingEnvironment(env) else {
            throw ValidationError("Not running inside a Zentty pane.")
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

    mutating func run() throws {
        let validDirections = ["right", "left", "up", "down"]
        guard validDirections.contains(direction) else {
            throw ValidationError("Invalid direction '\(direction)'. Use: \(validDirections.joined(separator: ", "))")
        }
        _ = try PaneIPC.send(subcommand: "split", arguments: [direction] + layout.layoutArguments())
    }
}

struct HSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hsplit",
        abstract: "Split horizontally (alias for 'split right')."
    )

    @OptionGroup var layout: SplitLayoutOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "split", arguments: ["right"] + layout.layoutArguments())
    }
}

struct VSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vsplit",
        abstract: "Split vertically (alias for 'split down')."
    )

    @OptionGroup var layout: SplitLayoutOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "split", arguments: ["down"] + layout.layoutArguments())
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

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    mutating func run() throws {
        let response = try PaneIPC.send(subcommand: "list")
        guard let entries = response?.result?.paneList, !entries.isEmpty else {
            print("No panes.")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        print("\(pad("ID", 4))  \(pad("COL", 3))  F  \(pad("TITLE", 16))  \(pad("CWD", 30))  \(pad("AGENT", 12))  STATUS")
        for entry in entries {
            let focus = entry.isFocused ? "*" : " "
            let cwd = entry.workingDirectory.map { abbreviateHome($0) } ?? "-"
            let agent = entry.agentTool ?? "-"
            let status = entry.agentStatus ?? "-"
            print("\(pad(String(entry.index), 4))  \(pad(String(entry.column), 3))  \(focus)  \(pad(String(entry.title.prefix(16)), 16))  \(pad(String(cwd.prefix(30)), 30))  \(pad(String(agent.prefix(12)), 12))  \(status)")
        }
    }

    private func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

struct PaneFocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus a pane by index, ID, or direction."
    )

    @Argument(help: "Pane index (1-based), pane ID, or direction (left/right/up/down).")
    var target: String

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "focus", arguments: [target])
    }
}

struct PaneCloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pane."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    mutating func run() throws {
        var args: [String] = []
        if let target {
            args.append(target)
        }
        _ = try PaneIPC.send(subcommand: "close", arguments: args)
    }
}

struct PaneZoomCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zoom",
        abstract: "Toggle zoomed-out pane view."
    )

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "zoom")
    }
}

struct PaneResizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resize",
        abstract: "Resize the focused pane."
    )

    @Argument(help: "Direction (left/right/up/down) or percentage (e.g. 60%).")
    var target: String

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "resize", arguments: [target])
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

    mutating func run() throws {
        var args = [preset]
        if vertical {
            args.append("--vertical")
        }
        _ = try PaneIPC.send(subcommand: "layout", arguments: args)
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
        "ZENTTY_CLAUDE_PID",
        "ZENTTY_CODEX_PID",
        "ZENTTY_COPILOT_PID",
        "ZENTTY_GEMINI_PID",
    ]

    @Argument(help: "Supported values: agent-event, agent-signal, agent-status")
    var subcommand: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded to the IPC subcommand.")
    var arguments: [String] = []

    mutating func run() throws {
        guard Self.supportedSubcommands.contains(subcommand) else {
            throw ValidationError("Unsupported ipc subcommand: \(subcommand)")
        }
        guard let socketPath = ProcessInfo.processInfo.environment["ZENTTY_INSTANCE_SOCKET"],
              !socketPath.isEmpty,
              Self.hasRequiredRoutingEnvironment(ProcessInfo.processInfo.environment) else {
            return
        }

        let request = AgentIPCRequest(
            kind: .ipc,
            arguments: arguments,
            standardInput: standardInput(),
            environment: Self.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: false,
            subcommand: subcommand
        )

        do {
            _ = try AgentIPCClient.send(request: request, socketPath: socketPath)
        } catch {
            guard ProcessInfo.processInfo.environment["ZENTTY_CLI_DEBUG"] == "1" else {
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
        for key in ["ZENTTY_PANE_TOKEN", "ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID"] {
            guard let value = environment[key], !value.isEmpty else {
                return false
            }
        }
        return true
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

    @Argument(help: "Supported values: claude, codex, copilot, gemini, opencode, pi")
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
