import Foundation

struct PaneOverlayIPCOptions: Equatable {
    enum Placement: String, CaseIterable {
        case worklane
        case pane
    }
    let command: String
    let workingDirectory: String?
    let wait: Bool
    let follow: Bool
    let notify: Bool
    let sizePercent: Int
    var placement: Placement = .worklane

    enum ParseError: LocalizedError, Equatable {
        case missingValue(String)
        case invalidValue(String)
        case missingCommand
        case unexpectedArgument(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let option): "Missing value for \(option)."
            case .invalidValue(let option): "Invalid value for \(option)."
            case .missingCommand: "Missing overlay command."
            case .unexpectedArgument(let argument): "Unexpected overlay argument: \(argument)."
            }
        }
    }

    static func parse(arguments: [String]) throws -> PaneOverlayIPCOptions {
        var commandTokens: [String]?
        var workingDirectory: String?
        var wait = false
        var follow = false
        var notify = false
        var sizePercent = 100
        var placement = Placement.worklane
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--wait": wait = true
            case "--follow": follow = true
            case "--notify": notify = true
            case "--cwd", "--size-percent", "--placement", "--command-json":
                guard arguments.indices.contains(index + 1) else { throw ParseError.missingValue(option) }
                let value = arguments[index + 1]
                switch option {
                case "--cwd":
                    guard !value.isEmpty else { throw ParseError.invalidValue(option) }
                    workingDirectory = value
                case "--size-percent":
                    guard let parsed = Int(value), (30...100).contains(parsed) else {
                        throw ParseError.invalidValue(option)
                    }
                    sizePercent = parsed
                case "--placement":
                    guard let parsed = Placement(rawValue: value) else {
                        throw ParseError.invalidValue(option)
                    }
                    placement = parsed
                default:
                    guard let data = value.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                        throw ParseError.invalidValue(option)
                    }
                    commandTokens = decoded
                }
                index += 1
            default: throw ParseError.unexpectedArgument(option)
            }
            index += 1
        }
        guard let commandTokens, !commandTokens.isEmpty else { throw ParseError.missingCommand }
        let command = try GridLaunchCommandBuilder.command(from: commandTokens)
        guard let nativeCommand = TmuxCompatIPCHandler.shellWrappedGhosttyCommand(command) else {
            throw ParseError.missingCommand
        }
        return PaneOverlayIPCOptions(
            command: nativeCommand,
            workingDirectory: workingDirectory,
            wait: wait,
            follow: follow,
            notify: notify,
            sizePercent: sizePercent,
            placement: placement
        )
    }
}

struct WebPaneIPCOptions {
    let url: String
    let placement: PaneOverlayIPCOptions.Placement
    let sizePercent: Int

    enum ParseError: LocalizedError {
        case missingValue(String)
        case invalidValue(String)
        case missingURL
        var errorDescription: String? {
            switch self {
            case .missingValue(let option): "Missing value for \(option)."
            case .invalidValue(let option): "Invalid value for \(option)."
            case .missingURL: "Missing URL or file path."
            }
        }
    }

    static func parse(arguments: [String]) throws -> WebPaneIPCOptions {
        var url: String?
        var placement: PaneOverlayIPCOptions.Placement = .pane
        var sizePercent = 100
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard arguments.indices.contains(index + 1) else { throw ParseError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--url": url = value
            case "--placement":
                if value == "overlay" { placement = .worklane }
                else if let parsed = PaneOverlayIPCOptions.Placement(rawValue: value) { placement = parsed }
                else { throw ParseError.invalidValue(option) }
            case "--size-percent":
                guard let parsed = Int(value), (30...100).contains(parsed) else { throw ParseError.invalidValue(option) }
                sizePercent = parsed
            default: throw ParseError.invalidValue(option)
            }
            index += 2
        }
        guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.missingURL }
        guard WebPreviewPolicy.resourceURL(url) != nil else { throw ParseError.invalidValue("--url") }
        return WebPaneIPCOptions(url: url, placement: placement, sizePercent: sizePercent)
    }
}
