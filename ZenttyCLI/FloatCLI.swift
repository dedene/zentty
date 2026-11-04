import ArgumentParser
import Foundation

// MARK: - zentty float new|list|hide|show

struct FloatCommandGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "float",
        abstract: "Open, list, hide, and show floating panes.",
        discussion: """
            A floating pane sits above the tiled panes of its worklane. Put it away as \
            picture in picture or as a pill in the bottom bar, or dock it back into the \
            layout, with 'zentty pane float|dock|pip|minimize|restore'.
            """,
        subcommands: [FloatNewCommand.self, FloatListCommand.self, FloatHideCommand.self, FloatShowCommand.self]
    )
}

struct FloatNewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Open a new floating pane in the calling pane's worklane.",
        discussion: """
            The float opens centred and focused, in the calling pane's directory unless --cwd \
            is given. A command after '--' is typed into its shell, like 'zentty split -- command'. \
            --temporary floats are not restored on relaunch and do not keep their worklane open. \
            Prints the new pane ID.
            """
    )

    @Option(name: .long, help: "Start in this directory (defaults to the calling pane's directory).")
    var cwd: String?

    @Flag(name: .long, help: "Do not restore the float when Zentty relaunches.")
    var temporary = false

    @OptionGroup var target: PaneTargetOptions

    @Argument(parsing: .postTerminator, help: "Optional command to run in the float. Place it after '--'.")
    var command: [String] = []

    mutating func run() throws {
        let options = FloatNewIPCOptions(
            workingDirectory: cwd.map { OverlayOpenCommand.absolutePath($0) },
            temporary: temporary,
            command: command
        )
        let response = try PaneIPC.send(
            subcommand: FloatControlIPC.newSubcommand,
            arguments: try options.arguments() + target.selectorArguments()
        )
        if let stdout = response?.result?.stdout {
            print(stdout, terminator: "")
        }
    }
}

struct FloatListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the floating panes of the calling pane's worklane.",
        discussion: """
            Shows each float's pane index (as in 'pane list'), its mode (floating, pip, minimized), \
            where it sits, and its status. In --json, 'frame' (floating) is in fractions of the \
            canvas with the origin top-left, and 'corner' (pip) is top-left, top-right, \
            bottom-left, or bottom-right.
            """
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        guard let entries = try PaneIPC.send(
            subcommand: FloatControlIPC.listSubcommand,
            arguments: target.selectorArguments()
        )?.result?.floatList else {
            throw ValidationError("This Zentty version does not support 'float list'.")
        }
        if json {
            try printJSON(entries)
            return
        }
        print(Self.table(entries), terminator: "")
    }

    static func table(_ entries: [FloatListEntry]) -> String {
        guard !entries.isEmpty else {
            return "No floating panes.\n"
        }
        var lines = ["\(pad("IDX", 3))  \(pad("MODE", 18))  \(pad("WHERE", 22))  F  \(pad("TITLE", 16))  STATUS"]
        for entry in entries {
            let mode = entry.isHidden ? "\(entry.mode) (hidden)" : entry.mode
            lines.append(
                "\(pad(String(entry.index), 3))  \(pad(mode, 18))  \(pad(placement(of: entry), 22))  "
                    + "\(focusMarker(entry.isFocused))  \(pad(String(entry.title.prefix(16)), 16))  \(statusWord(entry.status))"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `60%x60% at 20%,20%` for a float, the corner for a PiP, `-` for a pill.
    static func placement(of entry: FloatListEntry) -> String {
        if let frame = entry.frame {
            func percent(_ value: Double) -> String {
                "\(Int((value * 100).rounded()))%"
            }
            return "\(percent(frame.width))x\(percent(frame.height)) at \(percent(frame.x)),\(percent(frame.y))"
        }
        return entry.corner ?? "-"
    }

    static func statusWord(_ status: String) -> String {
        switch status {
        case "working": "Working"
        case "needs-input": "Needs input"
        case "done": "Done"
        case "stopped": "Stopped"
        case "check-back": "Check back"
        case "running": "Running"
        case "idle": "Idle"
        default: status
        }
    }
}

struct FloatHideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide the floats and picture-in-picture panes of the calling pane's worklane.",
        discussion: "Pills stay in the bottom bar. Hidden panes keep running."
    )

    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: FloatControlIPC.hideSubcommand, arguments: target.selectorArguments())
    }
}

struct FloatShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the hidden floats of the calling pane's worklane."
    )

    @OptionGroup var target: PaneTargetOptions

    mutating func run() throws {
        _ = try PaneIPC.send(subcommand: FloatControlIPC.showSubcommand, arguments: target.selectorArguments())
    }
}

// MARK: - zentty pane float|dock|pip|minimize|restore

private enum PaneFloatActionCLI {
    static func send(
        _ action: PaneFloatAction,
        target: String?,
        corner: String? = nil,
        selection: PaneTargetOptions
    ) throws {
        try selection.validatedForPositionalPaneSelector(target)
        if let corner, !FloatControlIPC.cornerNames.contains(corner) {
            throw ValidationError(
                "Invalid corner '\(corner)'. Use: \(FloatControlIPC.cornerNames.joined(separator: ", "))"
            )
        }
        let options = PaneFloatIPCOptions(target: target, corner: corner)
        _ = try PaneIPC.send(
            subcommand: action.subcommand,
            arguments: options.arguments() + selection.selectorArguments()
        )
    }
}

struct PaneFloatCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "float",
        abstract: "Float a pane above the layout.",
        discussion: "A tile lifts out of the layout where it is; a picture-in-picture pane or a pill comes back as a float. Already floating is a no-op."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try PaneFloatActionCLI.send(.float, target: target, selection: selection)
    }
}

struct PaneDockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock",
        abstract: "Dock a floating pane back into the layout.",
        discussion: "The pane returns to the column it was floated from (a new pane goes after the focused column). A tile is a no-op."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try PaneFloatActionCLI.send(.dock, target: target, selection: selection)
    }
}

struct PanePipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pip",
        abstract: "Shrink a pane to picture in picture.",
        discussion: """
            A tile is floated first. Without --corner a picture-in-picture pane keeps its corner, \
            others go bottom-right. A corner holds two; a third sends the oldest to the bottom bar.
            """
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @Option(name: .long, help: "top-left, top-right, bottom-left, or bottom-right.")
    var corner: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try PaneFloatActionCLI.send(.pip, target: target, corner: corner, selection: selection)
    }
}

struct PaneMinimizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "minimize",
        abstract: "Put a pane away as a pill in the bottom bar.",
        discussion: "A tile is floated first. The pane keeps running; 'pane restore' brings it back."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try PaneFloatActionCLI.send(.minimize, target: target, selection: selection)
    }
}

struct PaneRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Bring a picture-in-picture pane or pill back as a focused float.",
        discussion: "On a float it raises and focuses it. Fails on a tile."
    )

    @Argument(help: "Pane index or ID. Defaults to the current pane.")
    var target: String?

    @OptionGroup var selection: PaneTargetOptions

    mutating func run() throws {
        try PaneFloatActionCLI.send(.restore, target: target, selection: selection)
    }
}
