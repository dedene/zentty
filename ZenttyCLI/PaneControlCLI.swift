import ArgumentParser
import Darwin
import Foundation

// MARK: - pane send / send-key / read, events

private enum PaneControlCLIIPC {
    static func socketPath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["ZENTTY_INSTANCE_SOCKET"], !socketPath.isEmpty else {
            throw ValidationError("Not running inside a Zentty instance.")
        }
        return socketPath
    }

    static func request(subcommand: String, arguments: [String], standardInput: String? = nil) -> AgentIPCRequest {
        AgentIPCRequest(
            kind: .pane,
            arguments: arguments,
            standardInput: standardInput,
            environment: IPCCommand.forwardedEnvironment(from: ProcessInfo.processInfo.environment),
            expectsResponse: true,
            subcommand: subcommand
        )
    }

    static func send(
        subcommand: String,
        arguments: [String],
        standardInput: String? = nil,
        maxResponseBytes: Int? = nil
    ) throws -> AgentIPCResponse? {
        let socketPath = try socketPath()
        let request = request(subcommand: subcommand, arguments: arguments, standardInput: standardInput)
        if let maxResponseBytes {
            return try AgentIPCClient.send(request: request, socketPath: socketPath, maxResponseBytes: maxResponseBytes)
        }
        return try AgentIPCClient.send(request: request, socketPath: socketPath)
    }
}

extension PaneTargetOptions {
    /// Whether the command names its destination instead of falling back to
    /// the calling pane.
    func namesDestination(positionalTarget: String?) -> Bool {
        positionalTarget != nil || hasExplicitPaneSelector || worklaneID != nil || windowID != nil
    }
}

struct PaneSendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Type text into a pane, then press Enter.",
        discussion: """
            Text comes after '--'. Without '--', it is read from stdin when stdin is a pipe or a file \
            (one trailing newline is dropped). Empty text is an error; to press Enter alone, use \
            'pane send-key <pane> Enter'. Multi-line text is always delivered as a paste. \
            The destination must be named: a pane index or ID, or --pane-id/--pane-index/--worklane-id. \
            Refuses while an agent in the pane is mid-turn or showing an approval, decision, or sign-in \
            prompt, unless --force is given.
            """
    )

    @Argument(help: "Pane index (1-based) or pane ID in the current worklane.")
    var target: String?

    @Flag(name: .customLong("no-enter"), help: "Type the text without pressing Enter.")
    var noEnter = false

    @Flag(name: .long, help: "Deliver the text as a paste (bracketed when the program enabled it).")
    var paste = false

    @Flag(name: .long, help: "Send even when the agent in the pane is mid-turn or showing a prompt.")
    var force = false

    @OptionGroup var selection: PaneTargetOptions

    @Argument(parsing: .postTerminator, help: "Text to send. Place it after '--'.")
    var text: [String] = []

    mutating func run() throws {
        try selection.validatedForPositionalPaneSelector(target)
        guard selection.namesDestination(positionalTarget: target) else {
            throw ValidationError("Name the destination pane (index, ID, or --pane-id). Sending to your own pane must be explicit.")
        }
        let payload = resolvedText()
        guard !payload.isEmpty else {
            throw ValidationError(PaneControlIPCError.missingText.localizedDescription)
        }
        let options = PaneSendIPCOptions(target: target, submit: !noEnter, paste: paste, force: force)
        let arguments = options.arguments() + selection.selectorArguments()
        do {
            try PaneControlIPC.validateSendSize(
                text: payload,
                request: PaneControlCLIIPC.request(
                    subcommand: PaneControlIPC.sendSubcommand,
                    arguments: arguments,
                    standardInput: payload
                )
            )
        } catch let error as PaneControlIPCError {
            throw ValidationError(error.localizedDescription)
        }
        _ = try PaneControlCLIIPC.send(
            subcommand: PaneControlIPC.sendSubcommand,
            arguments: arguments,
            standardInput: payload
        )
    }

    private func resolvedText() -> String {
        if !text.isEmpty {
            return text.joined(separator: " ")
        }
        // An explicit '--' with nothing after it (an empty variable) is
        // empty text, never a cue to wait on stdin.
        guard !CommandLine.arguments.contains("--"), PaneSendStandardInput.isPipeOrFile(STDIN_FILENO) else {
            return ""
        }
        return PaneSendStandardInput.trimmingFinalNewline(
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

enum PaneSendStandardInput {
    /// Only a pipe or a regular file is read. A terminal, `/dev/null`, or a
    /// socket a tool runner leaves open would mean an empty send or a hang.
    static func isPipeOrFile(_ fileDescriptor: Int32) -> Bool {
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            return false
        }
        let type = status.st_mode & S_IFMT
        return type == S_IFIFO || type == S_IFREG
    }

    static func trimmingFinalNewline(_ input: String) -> String {
        var input = input
        if input.hasSuffix("\r\n") || input.hasSuffix("\n") {
            // "\r\n" is a single Character in Swift.
            input.removeLast()
        }
        return input
    }
}

struct PaneSendKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-key",
        abstract: "Press keys in a pane.",
        discussion: """
            Key names: Enter, Escape, Tab, BTab, Space, BSpace, Up, Down, Left, Right, Home, End, \
            PageUp, PageDown, Insert, Delete, F1-F12, C-<letter> (control), M-<key> (meta), \
            or any single character. A leading pane index or ID picks the pane; otherwise use \
            --pane-id/--pane-index/--worklane-id. Like 'pane send', refuses while an agent in the pane \
            is mid-turn or showing a prompt unless --force is given; C-c and Escape always go through.
            """
    )

    @Argument(help: "Optional pane index or ID, then one or more key names.")
    var tokens: [String] = []

    @Flag(name: .long, help: "Send even when the agent in the pane is mid-turn or showing a prompt.")
    var force = false

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        let split = PaneSendKeyIPCOptions.splitTarget(tokens, hasExplicitPaneSelector: selection.hasExplicitPaneSelector)
        guard !split.keys.isEmpty else {
            throw ValidationError(PaneControlIPCError.missingKeys.localizedDescription)
        }
        guard selection.namesDestination(positionalTarget: split.target) else {
            throw ValidationError("Name the destination pane (index, ID, or --pane-id). Sending to your own pane must be explicit.")
        }
        do {
            _ = try PaneKeyNames.strokes(for: split.keys)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        let options = PaneSendKeyIPCOptions(target: split.target, keys: split.keys, force: force)
        _ = try PaneControlCLIIPC.send(
            subcommand: PaneControlIPC.sendKeySubcommand,
            arguments: options.arguments() + selection.selectorArguments()
        )
    }
}

struct PaneReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Print a pane's screen.",
        discussion: "Prints the visible screen by default. Defaults to the calling pane."
    )

    @Argument(help: "Pane index (1-based) or pane ID in the current worklane.")
    var target: String?

    @Option(name: .long, help: "Only the last N lines.")
    var lines: Int?

    @Flag(name: .long, help: "Include scrollback history, not just the visible screen.")
    var scrollback = false

    @Flag(name: .long, help: "Output as JSON with pane ID and terminal size.")
    var json = false

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try selection.validatedForPositionalPaneSelector(target)
        if let lines, lines <= 0 {
            throw ValidationError("--lines must be a positive number.")
        }
        let options = PaneReadIPCOptions(target: target, lineLimit: lines, includeScrollback: scrollback)
        guard let result = try PaneControlCLIIPC.send(
            subcommand: PaneControlIPC.readSubcommand,
            arguments: options.arguments() + selection.selectorArguments(),
            maxResponseBytes: PaneControlIPC.maxReadResponseBytes
        )?.result?.paneRead else {
            throw ValidationError("This Zentty version does not support 'pane read'.")
        }
        if json {
            try printJSON(result)
            return
        }
        let text = result.text
        FileHandle.standardOutput.write(Data((text.hasSuffix("\n") || text.isEmpty ? text : text + "\n").utf8))
    }
}

struct EventsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Stream workspace events until interrupted.",
        discussion: """
            Reports agent phase changes, attention raised/cleared, panes created/closed/moved/focused, \
            and worklanes created/closed. --type takes an event type (agent.phase) or a family (pane); \
            repeat it to select several. --json prints one JSON object per line: {"v":1,"type":...,"ts":...}.
            """
    )

    @Flag(name: .long, help: "Output newline-delimited JSON.")
    var json = false

    @Option(name: .customLong("type"), help: "Only events of this type or family. Repeatable.")
    var types: [String] = []

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        let options: PaneEventsIPCOptions
        do {
            options = try PaneEventsIPCOptions.parse(arguments: types.flatMap { ["--type", $0] })
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        let request = PaneControlCLIIPC.request(
            subcommand: PaneControlIPC.eventsSubcommand,
            arguments: options.arguments() + selection.selectorArguments()
        )
        let json = json
        let decoder = JSONDecoder()
        try AgentIPCClient.stream(request: request, socketPath: try PaneControlCLIIPC.socketPath()) { line in
            let output: Data
            if json {
                output = line + Data([UInt8(ascii: "\n")])
            } else if let event = try? decoder.decode(PaneEvent.self, from: line) {
                output = Data((Self.humanLine(for: event) + "\n").utf8)
            } else {
                return true
            }
            // Unbuffered, so piped consumers see each event as it happens.
            FileHandle.standardOutput.write(output)
            return true
        }
    }

    static func humanLine(for event: PaneEvent) -> String {
        let fields: [(String, String?)] = [
            ("pane", event.pane),
            ("worklane", event.worklane),
            ("agent", event.agent),
            ("phase", event.phase),
            ("from", event.previousPhase),
            ("interaction", event.interaction),
            ("attention", event.attention ?? event.previousAttention),
            ("from_worklane", event.fromWorklane),
            ("count", event.count.map(String.init)),
        ]
        let rendered = fields.compactMap { key, value in value.map { "\(key)=\($0)" } }
        return ([event.ts, event.type] + rendered).joined(separator: "  ")
    }
}
