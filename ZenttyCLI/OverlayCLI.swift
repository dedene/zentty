import ArgumentParser
import Foundation

struct OverlayCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "overlay",
        abstract: "Run a temporary terminal over a pane without changing worklanes.",
        subcommands: [OverlayOpenCommand.self, OverlayListCommand.self,
                      OverlayShowCommand.self, OverlayCloseCommand.self]
    )
}

struct OverlayOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open an overlay on the calling or selected pane."
    )

    @Argument(parsing: .captureForPassthrough,
              help: "Use [--wait] [--follow] [--notify] [--cwd DIR] [--placement worklane|pane] [--size-percent N] [pane selectors] -- command ...")
    var rawArguments: [String] = []

    mutating func run() throws {
        let optionArguments = rawArguments.prefix { $0 != "--" }
        if optionArguments.contains("--help") || optionArguments.contains("-h") {
            print("""
            OVERVIEW: Run a temporary command over a pane without changing its worklane layout.

            USAGE: zentty overlay open [--wait] [--follow] [--notify] [--cwd DIR] [--placement worklane|pane] [--size-percent N] [--window-id ID] [--worklane-id ID] [--pane-id ID] [--pane-index N] [--pane-token TOKEN] -- command ...

            OPTIONS:
              --wait             Keep the terminal open after the command exits.
              --follow           Select the target worklane and focus the overlay.
              --notify           Notify the target pane and add an inbox entry.
              --cwd DIR          Run from this directory (defaults to the target pane's directory).
              --placement MODE   Float over the worklane or target pane (default worklane).
              --size-percent N   Percentage of the inset content area (30–100, default 100).
            """)
            return
        }
        guard let separator = rawArguments.firstIndex(of: "--") else {
            throw ValidationError("Use '--' before the command to run in the overlay.")
        }
        let command = Array(rawArguments[(separator + 1)...])
        guard !command.isEmpty else {
            throw ValidationError("Missing overlay command.")
        }
        let data = try JSONEncoder().encode(command)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ValidationError("Unable to encode overlay command.")
        }
        let options = Array(rawArguments[..<separator])
        let response = try PaneIPC.send(
            subcommand: "overlay-open",
            arguments: options + ["--command-json", json]
        )
        if let stdout = response?.result?.stdout {
            print(stdout, terminator: "")
        }
    }
}

struct OverlayListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List overlays for the calling or selected pane and its worklane.")
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        let response = try PaneIPC.send(subcommand: "overlay-list", arguments: target.selectorArguments())
        if let stdout = response?.result?.stdout { print(stdout, terminator: "") }
    }
}

struct OverlayShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Reveal the target pane's overlay.")
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "overlay-show", arguments: target.selectorArguments())
    }
}

struct OverlayCloseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close the target pane's overlay.")
    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: "overlay-close", arguments: target.selectorArguments())
    }
}

struct WebCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web", abstract: "Open web content inside Zentty.", subcommands: [WebOpenCommand.self, WebOverlayCommand.self])
}

struct WebOpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a URL or local HTML file in a new pane.")
    @OptionGroup var options: WebResourceOptions
    mutating func run() throws { try options.open(placement: "pane") }
}

struct WebOverlayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "overlay", abstract: "Open a URL or local HTML file over the worklane, like Ctrl+`.")
    @OptionGroup var options: WebResourceOptions
    mutating func run() throws { try options.open(placement: "overlay") }
}

struct WebResourceOptions: ParsableArguments {
    @Option(name: .long, help: "Overlay size as a percentage (30–100).")
    var sizePercent = 100
    @OptionGroup var target: PaneTargetOptions
    @Argument(help: "URL or local file path.")
    var resource: String

    func open(placement: String) throws {
        guard (30...100).contains(sizePercent) else { throw ValidationError("--size-percent must be between 30 and 100.") }
        guard !resource.isEmpty else {
            throw ValidationError("Pass a URL or file path.")
        }
        let value = resource
        let resolvedValue: String
        if value.hasPrefix("file://") || value.contains("://") {
            resolvedValue = value
        } else {
            let expanded = (value as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ValidationError("File does not exist: \(fileURL.path)") }
            resolvedValue = fileURL.absoluteString
        }
        var arguments = ["--url", resolvedValue, "--size-percent", String(sizePercent)]
        arguments.append(contentsOf: ["--placement", placement])
        arguments.append(contentsOf: target.selectorArguments())
        let response = try PaneIPC.send(subcommand: "web-open", arguments: arguments)
        if let stdout = response?.result?.stdout { print(stdout, terminator: "") }
    }
}
