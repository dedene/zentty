import Foundation

/// Wire contract for `zentty pane float|dock|pip|minimize|restore` and
/// `zentty float new|list|hide|show`. Compiled into both the app and the CLI
/// so the argument shapes cannot drift apart.
///
/// All ride `kind: .pane` requests, so they share the selector and pane-token
/// rules of the other pane commands: the routing selectors (`--pane-id`,
/// `--worklane-id`, ...) pick the calling pane and its worklane, and the
/// handler-private flags below pass through `ParsedPaneSelectors` untouched.
enum FloatControlIPC {
    static let newSubcommand = "float-new"
    static let listSubcommand = "float-list"
    static let hideSubcommand = "float-hide"
    static let showSubcommand = "float-show"

    /// PiP corners as the CLI spells them.
    static let cornerNames = ["top-left", "top-right", "bottom-left", "bottom-right"]
}

enum FloatControlIPCError: LocalizedError, Equatable {
    case missingValue(String)
    case invalidValue(String, String)
    case unexpectedArgument(String)
    case invalidCommandJSON
    case cornerOnlyForPip
    case notFloating(String)
    case invalidWorkingDirectory(String)
    case busy
    case soleTile(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            "Missing value for \(option)."
        case .invalidValue(let option, let value):
            "Invalid value for \(option): \(value)."
        case .unexpectedArgument(let argument):
            "Unexpected argument: \(argument)."
        case .invalidCommandJSON:
            "Invalid float command payload."
        case .cornerOnlyForPip:
            "--corner only applies to 'pane pip'."
        case .notFloating(let paneID):
            "Pane \(paneID) is a tile, not a floating pane. Use 'zentty pane float' to float it."
        case .invalidWorkingDirectory(let path):
            "Working directory does not exist: \(path)"
        case .busy:
            "Zentty is in the middle of a pane drag or worklane preview. Try again once it ends."
        case .soleTile(let paneID):
            "Pane \(paneID) is the only tile in its worklane and stays docked. Split or open another pane first."
        }
    }
}

/// `zentty pane <action> [pane]`: where a pane should end up. Every action is
/// idempotent; a tile is floated first when the action needs a float.
enum PaneFloatAction: String, CaseIterable, Equatable, Sendable {
    /// Tile → float (lifted in place); PiP or pill → float.
    case float
    /// Float, PiP or pill → back into the strip where it came from.
    case dock
    /// Tile, float or pill → picture in picture.
    case pip
    /// Tile, float or PiP → pill in the bottom bar.
    case minimize
    /// PiP or pill → float, raised and focused. Fails on a tile.
    case restore

    var subcommand: String {
        "pane-\(rawValue)"
    }

    init?(subcommand: String) {
        guard subcommand.hasPrefix("pane-") else {
            return nil
        }
        self.init(rawValue: String(subcommand.dropFirst("pane-".count)))
    }
}

/// Arguments for `pane float|dock|pip|minimize|restore`.
struct PaneFloatIPCOptions: Equatable, Sendable {
    /// Pane index or ID in the calling worklane; nil is the calling pane.
    var target: String?
    /// PiP corner (`FloatControlIPC.cornerNames`), `pane pip` only.
    var corner: String?

    func arguments() -> [String] {
        var arguments: [String] = []
        if let target {
            arguments += ["--target", target]
        }
        if let corner {
            arguments += ["--corner", corner]
        }
        return arguments
    }

    static func parse(arguments: [String], action: PaneFloatAction) throws -> PaneFloatIPCOptions {
        var options = PaneFloatIPCOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--target":
                options.target = try FloatControlArgumentReader.value(after: argument, in: arguments, at: index)
                index += 2
            case "--corner":
                let raw = try FloatControlArgumentReader.value(after: argument, in: arguments, at: index)
                guard action == .pip else {
                    throw FloatControlIPCError.cornerOnlyForPip
                }
                guard FloatControlIPC.cornerNames.contains(raw) else {
                    throw FloatControlIPCError.invalidValue(argument, raw)
                }
                options.corner = raw
                index += 2
            default:
                throw FloatControlIPCError.unexpectedArgument(argument)
            }
        }
        return options
    }
}

/// Arguments for `float new`. The command travels as JSON tokens, like
/// `zentty split -- command`.
struct FloatNewIPCOptions: Equatable, Sendable {
    var workingDirectory: String?
    var temporary: Bool = false
    var command: [String] = []

    func arguments() throws -> [String] {
        var arguments: [String] = []
        if let workingDirectory {
            arguments += ["--cwd", workingDirectory]
        }
        if temporary {
            arguments.append("--temporary")
        }
        if !command.isEmpty {
            let data = try JSONEncoder().encode(command)
            arguments += ["--command-json", String(decoding: data, as: UTF8.self)]
        }
        return arguments
    }

    static func parse(arguments: [String]) throws -> FloatNewIPCOptions {
        var options = FloatNewIPCOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--cwd":
                let raw = try FloatControlArgumentReader.value(after: argument, in: arguments, at: index)
                guard !raw.isEmpty else {
                    throw FloatControlIPCError.invalidValue(argument, raw)
                }
                options.workingDirectory = raw
                index += 2
            case "--temporary":
                options.temporary = true
                index += 1
            case "--command-json":
                let raw = try FloatControlArgumentReader.value(after: argument, in: arguments, at: index)
                guard let tokens = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
                    throw FloatControlIPCError.invalidCommandJSON
                }
                options.command = tokens
                index += 2
            default:
                throw FloatControlIPCError.unexpectedArgument(argument)
            }
        }
        return options
    }
}

/// Arguments for `float hide|show`, `float list`: none beyond the routing
/// selectors, so anything left over is a mistake.
enum FloatWorklaneIPCOptions {
    static func validate(arguments: [String]) throws {
        if let argument = arguments.first {
            throw FloatControlIPCError.unexpectedArgument(argument)
        }
    }
}

/// One row of `float list`.
struct FloatListEntry: Codable, Equatable, Sendable {
    /// Fractions of the canvas, origin top-left (like screen reading order).
    struct Frame: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let id: String
    /// Same numbering as `pane list`; pane commands accept it.
    let index: Int
    let worklaneID: String
    let windowID: String?
    let title: String
    let workingDirectory: String?
    /// `floating`, `pip` or `minimized`.
    let mode: String
    /// Set while `floating`: where the float sits.
    let frame: Frame?
    /// Set while `pip`: one of `FloatControlIPC.cornerNames`.
    let corner: String?
    /// `working`, `needs-input`, `done`, `stopped`, `check-back`, `running`
    /// (a shell command, no agent) or `idle`.
    let status: String
    let agentTool: String?
    let isFocused: Bool
    /// Hidden with the worklane's other floats (`float hide`, ⌥⌘.). Pills
    /// never hide.
    let isHidden: Bool
    /// Not restored on relaunch (`float new --temporary`, overlays).
    let isTemporary: Bool
}

enum FloatControlArgumentReader {
    static func value(after option: String, in arguments: [String], at index: Int) throws -> String {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex) else {
            throw FloatControlIPCError.missingValue(option)
        }
        return arguments[valueIndex]
    }
}
