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
        let options = Self.absolutizingWorkingDirectory(in: Array(rawArguments[..<separator]))
        let response = try PaneIPC.send(
            subcommand: "overlay-open",
            arguments: options + ["--command-json", json]
        )
        if let stdout = response?.result?.stdout {
            print(stdout, terminator: "")
        }
    }

    /// The app resolves `--cwd` against its own working directory, so relative
    /// and `~` paths must be made absolute here, where the caller's directory is known.
    static func absolutizingWorkingDirectory(
        in options: [String],
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> [String] {
        var options = options
        for index in options.indices.dropLast() where options[index] == "--cwd" {
            let path = (options[index + 1] as NSString).expandingTildeInPath
            guard !path.isEmpty else { continue }
            let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
            options[index + 1] = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
        }
        return options
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
