import AppKit
import Foundation

/// Parses `worklane-rename` IPC arguments. `title == nil` means clear.
/// Returns nil when neither `--clear` nor a `--title` value is present.
enum WorklaneRenameIPCParser {
    struct Parsed: Equatable {
        var title: String?
        var worklaneIDOverride: String?
    }

    static func parse(_ arguments: [String]) -> Parsed? {
        let title: String?
        if arguments.contains("--clear") {
            title = nil
        } else if let titleIndex = arguments.firstIndex(of: "--title"),
                  titleIndex + 1 < arguments.count {
            title = arguments[titleIndex + 1]
        } else {
            return nil
        }

        var worklaneIDOverride: String?
        if let overrideIndex = arguments.firstIndex(of: "--id"),
           overrideIndex + 1 < arguments.count {
            worklaneIDOverride = arguments[overrideIndex + 1]
        }

        return Parsed(title: title, worklaneIDOverride: worklaneIDOverride)
    }
}

enum PaneIPCSubcommand: String {
    case split
    case grid
    case list
    case focus
    case close
    case resize
    case layout
    case notify
    case worklaneColor = "worklane-color"
    case worklaneRename = "worklane-rename"
    case theme
}

enum PaneThemeIPCError: LocalizedError {
    case missingCommand
    case unsupportedCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            "Missing theme command."
        case .unsupportedCommand(let command):
            "Unsupported theme command: \(command)"
        }
    }
}

enum PaneGridIPCError: LocalizedError {
    case missingValue(String)
    case invalidValue(String, String)
    case invalidCommandJSON
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .invalidValue(let option, let value):
            return "Invalid value for \(option): \(value)."
        case .invalidCommandJSON:
            return "Invalid grid command payload."
        case .unexpectedArgument(let argument):
            return "Unexpected grid argument: \(argument)."
        }
    }
}

private struct PaneGridIPCOptions {
    enum Destination: Equatable {
        case current
        case newWorklane
        case newWindow
    }

    let rows: Int
    let columns: Int
    let command: String?
    let includeSource: Bool
    let focus: GridFocus
    let destination: Destination

    static func parse(arguments: [String]) throws -> PaneGridIPCOptions {
        var rows: Int?
        var columns: Int?
        var commandTokens: [String] = []
        var includeSource = true
        var focus = GridFocus.source
        var newWorklane = false
        var newWindow = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--rows":
                rows = try positiveIntegerValue(after: argument, in: arguments, at: index)
                index += 2
            case "--columns":
                columns = try positiveIntegerValue(after: argument, in: arguments, at: index)
                index += 2
            case "--command-json":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneGridIPCError.missingValue(argument)
                }
                guard let data = arguments[valueIndex].data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                    throw PaneGridIPCError.invalidCommandJSON
                }
                commandTokens = decoded
                index += 2
            case "--include-source":
                includeSource = true
                index += 1
            case "--new-only":
                includeSource = false
                index += 1
            case "--new-worklane":
                newWorklane = true
                index += 1
            case "--new-window":
                newWindow = true
                index += 1
            case "--focus":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneGridIPCError.missingValue(argument)
                }
                let raw = arguments[valueIndex]
                guard let parsed = GridFocus(rawValue: raw) else {
                    throw PaneGridIPCError.invalidValue(argument, raw)
                }
                focus = parsed
                index += 2
            default:
                throw PaneGridIPCError.unexpectedArgument(argument)
            }
        }

        guard let rows else {
            throw PaneGridIPCError.missingValue("--rows")
        }
        guard let columns else {
            throw PaneGridIPCError.missingValue("--columns")
        }

        let command = commandTokens.isEmpty
            ? nil
            : try GridLaunchCommandBuilder.command(from: commandTokens)
        let destination: Destination = if newWindow {
            .newWindow
        } else if newWorklane {
            .newWorklane
        } else {
            .current
        }
        return PaneGridIPCOptions(
            rows: rows,
            columns: columns,
            command: command,
            includeSource: includeSource,
            focus: focus,
            destination: destination
        )
    }

    private static func positiveIntegerValue(
        after option: String,
        in arguments: [String],
        at index: Int
    ) throws -> Int {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex) else {
            throw PaneGridIPCError.missingValue(option)
        }
        let raw = arguments[valueIndex]
        guard let value = Int(raw), value > 0 else {
            throw PaneGridIPCError.invalidValue(option, raw)
        }
        return value
    }
}

enum PaneNotificationIPCError: LocalizedError {
    case missingValue(String)
    case missingTitle
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .missingTitle:
            return "Missing notification title."
        case .unexpectedArgument(let argument):
            return "Unexpected notification argument: \(argument)."
        }
    }
}

private struct PaneNotificationIPCOptions {
    let title: String
    let subtitle: String?
    let body: String?
    let includeInbox: Bool
    let isSilent: Bool

    static func parse(arguments: [String]) throws -> PaneNotificationIPCOptions {
        var title: String?
        var subtitle: String?
        var body: String?
        var includeInbox = true
        var isSilent = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--title":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneNotificationIPCError.missingValue(argument)
                }
                title = trimmed(arguments[valueIndex])
                index += 2
            case "--subtitle":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneNotificationIPCError.missingValue(argument)
                }
                subtitle = trimmed(arguments[valueIndex])
                index += 2
            case "--body":
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw PaneNotificationIPCError.missingValue(argument)
                }
                body = trimmed(arguments[valueIndex])
                index += 2
            case "--no-inbox":
                includeInbox = false
                index += 1
            case "--silent":
                isSilent = true
                index += 1
            default:
                throw PaneNotificationIPCError.unexpectedArgument(argument)
            }
        }

        guard let title else {
            throw PaneNotificationIPCError.missingTitle
        }

        return PaneNotificationIPCOptions(
            title: title,
            subtitle: subtitle,
            body: body,
            includeInbox: includeInbox,
            isSilent: isSilent
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum PaneIPCHandler {
    static func handle(
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let subcommandString = request.subcommand,
              let subcommand = PaneIPCSubcommand(rawValue: subcommandString) else {
            throw AgentIPCError.unsupportedSubcommand(request.subcommand ?? "<nil>")
        }

        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try Self.dispatch(subcommand: subcommand, request: request, target: target)
            }
        }

        var result: Result<AgentIPCResponseResult, Error>!
        DispatchQueue.main.sync {
            result = MainActor.assumeIsolated {
                Result {
                    try Self.dispatch(subcommand: subcommand, request: request, target: target)
                }
            }
        }
        return try result.get()
    }

    @MainActor
    private static func dispatch(
        subcommand: PaneIPCSubcommand,
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let resolved = resolveTarget(target, appDelegate: appDelegate) else {
            if subcommand == .notify {
                throw PaneRoutingError.paneNotFound
            }
            return AgentIPCResponseResult()
        }
        let windowController = resolved.windowController
        let target = resolved.target

        if subcommand == .notify,
           !windowController.containsPane(worklaneID: target.worklaneID, paneID: target.paneID) {
            throw PaneRoutingError.paneNotFound
        }

        if subcommand != .list && subcommand != .worklaneColor && subcommand != .worklaneRename
            && subcommand != .notify && subcommand != .theme {
            windowController.focusPane(id: target.paneID, in: target.worklaneID)
        }

        switch subcommand {
        case .split:
            return handleSplit(arguments: request.arguments, windowController: windowController)
        case .grid:
            return try handleGrid(
                arguments: request.arguments,
                target: target,
                windowController: windowController,
                appDelegate: appDelegate
            )
        case .list:
            return handleList(target: target, windowController: windowController)
        case .focus:
            return handleFocus(arguments: request.arguments, target: target, windowController: windowController)
        case .close:
            return handleClose(arguments: request.arguments, target: target, windowController: windowController)
        case .resize:
            return handleResize(arguments: request.arguments, windowController: windowController)
        case .layout:
            return handleLayout(arguments: request.arguments, windowController: windowController)
        case .notify:
            return try handleNotify(arguments: request.arguments, target: target, appDelegate: appDelegate)
        case .worklaneColor:
            return handleWorklaneColor(arguments: request.arguments, target: target, windowController: windowController)
        case .worklaneRename:
            return handleWorklaneRename(arguments: request.arguments, target: target, windowController: windowController)
        case .theme:
            return try handleTheme(arguments: request.arguments, windowController: windowController)
        }
    }

    @MainActor
    private static func handleTheme(
        arguments: [String],
        windowController: MainWindowController
    ) throws -> AgentIPCResponseResult {
        guard let rawCommand = arguments.first else {
            throw PaneThemeIPCError.missingCommand
        }
        guard let command = AppearanceThemeModeCommand(rawValue: rawCommand) else {
            throw PaneThemeIPCError.unsupportedCommand(rawCommand)
        }

        let result = windowController.applyThemeModeCommand(command)
        return AgentIPCResponseResult(stdout: "\(result.cliToken)\n")
    }

    @MainActor
    private static func handleGrid(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController,
        appDelegate: AppDelegate
    ) throws -> AgentIPCResponseResult {
        let options = try PaneGridIPCOptions.parse(arguments: arguments)
        switch options.destination {
        case .current:
            let result = try windowController.applyGrid(
                sourcePaneID: target.paneID,
                rows: options.rows,
                columns: options.columns,
                command: options.command,
                includeSource: false,
                focus: options.focus
            )
            if options.includeSource, let command = options.command {
                _ = windowController.submitCommand(command, to: result.sourcePaneID)
            }
        case .newWorklane:
            guard let source = windowController.createWorklaneForGrid() else {
                throw GridApplicationError.sourcePaneNotFound
            }
            let result = try windowController.applyGrid(
                sourcePaneID: source.paneID,
                rows: options.rows,
                columns: options.columns,
                command: options.command,
                includeSource: options.includeSource,
                focus: options.focus
            )
            if options.includeSource, let command = options.command {
                _ = windowController.submitCommand(command, to: result.sourcePaneID)
            }
        case .newWindow:
            _ = try appDelegate.createGridWindow(
                inheritingFrom: windowController,
                sourcePaneID: target.paneID,
                rows: options.rows,
                columns: options.columns,
                command: options.command,
                includeSource: options.includeSource,
                focus: options.focus
            )
        }
        return AgentIPCResponseResult()
    }

    @MainActor
    private static func handleNotify(
        arguments: [String],
        target: AgentIPCTarget,
        appDelegate: AppDelegate
    ) throws -> AgentIPCResponseResult {
        let options = try PaneNotificationIPCOptions.parse(arguments: arguments)
        guard let windowID = target.windowID else {
            throw PaneRoutingError.paneNotFound
        }

        appDelegate.deliverPaneNotification(
            PaneNotificationRequest(
                title: options.title,
                subtitle: options.subtitle,
                body: options.body,
                includeInbox: options.includeInbox,
                isSilent: options.isSilent,
                windowID: windowID,
                worklaneID: target.worklaneID,
                paneID: target.paneID
            )
        )
        return AgentIPCResponseResult()
    }

    @MainActor
    private static func resolveTarget(
        _ target: AgentIPCTarget,
        appDelegate: AppDelegate
    ) -> (windowController: MainWindowController, target: AgentIPCTarget)? {
        let exactWindowController = target.windowID
            .flatMap(appDelegate.windowController(with:))
            .flatMap { controller in
                controller.containsPane(worklaneID: target.worklaneID, paneID: target.paneID) ? controller : nil
            }
        let paneOwner = appDelegate.windowController(containingPane: target.paneID)
        let worklaneOwner = appDelegate.windowController(containingWorklane: target.worklaneID)

        guard let windowController = exactWindowController ?? paneOwner ?? worklaneOwner else {
            return nil
        }

        let resolvedWorklaneID = windowController.worklaneID(containing: target.paneID) ?? target.worklaneID
        let resolvedTarget = AgentIPCTarget(
            windowID: windowController.windowID,
            worklaneID: resolvedWorklaneID,
            paneID: target.paneID
        )
        return (windowController, resolvedTarget)
    }

    // MARK: - Worklane color

    @MainActor
    private static func handleWorklaneColor(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        guard let colorIndex = arguments.firstIndex(of: "--color"),
              colorIndex + 1 < arguments.count else {
            return AgentIPCResponseResult()
        }
        let rawColor = arguments[colorIndex + 1]

        let resolvedColor: WorklaneColor?
        if rawColor == "reset" || rawColor == "default" {
            resolvedColor = nil
        } else if let color = WorklaneColor(rawValue: rawColor) {
            resolvedColor = color
        } else {
            return AgentIPCResponseResult()
        }

        let worklaneID: WorklaneID
        if let overrideIndex = arguments.firstIndex(of: "--id"),
           overrideIndex + 1 < arguments.count {
            worklaneID = WorklaneID(arguments[overrideIndex + 1])
        } else {
            worklaneID = target.worklaneID
        }

        _ = windowController.setWorklaneColor(resolvedColor, on: worklaneID)
        return AgentIPCResponseResult()
    }

    @MainActor
    private static func handleWorklaneRename(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        guard let parsed = WorklaneRenameIPCParser.parse(arguments) else {
            return AgentIPCResponseResult()
        }

        let worklaneID = parsed.worklaneIDOverride.map(WorklaneID.init) ?? target.worklaneID
        _ = windowController.setWorklaneTitle(parsed.title, on: worklaneID)
        return AgentIPCResponseResult()
    }

    // MARK: - Split

    @MainActor
    private static func handleSplit(
        arguments: [String],
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let direction = arguments.first ?? "right"
        let placement: PanePlacement
        let isHorizontal: Bool
        switch direction {
        case "right":
            placement = .afterFocused
            isHorizontal = true
        case "left":
            placement = .beforeFocused
            isHorizontal = true
        case "down":
            placement = .afterFocused
            isHorizontal = false
        case "up":
            placement = .beforeFocused
            isHorizontal = false
        default:
            return AgentIPCResponseResult()
        }

        let layout = parseSplitLayout(from: arguments)

        if layout == .none {
            let command: PaneCommand = isHorizontal
                ? (placement == .afterFocused ? .splitAfterFocusedPane : .splitBeforeFocusedPane)
                : (placement == .afterFocused ? .splitVertically : .splitVerticallyBefore)
            windowController.handlePaneIPCCommand(command)
        } else {
            windowController.splitWithLayout(placement: placement, isHorizontal: isHorizontal, layout: layout)
        }

        return AgentIPCResponseResult()
    }

    private static func parseSplitLayout(from arguments: [String]) -> SplitLayoutAction {
        if arguments.contains("--equal") {
            return .equal
        }
        if arguments.contains("--golden") {
            return .golden
        }
        if let ratioIndex = arguments.firstIndex(of: "--ratio"),
           ratioIndex + 1 < arguments.count,
           let value = Int(arguments[ratioIndex + 1]),
           value > 0, value <= 100 {
            return .ratio(CGFloat(value) / 100.0)
        }
        return .none
    }

    // MARK: - List

    @MainActor
    private static func handleList(
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let entries = windowController.paneListEntries(for: target.worklaneID)
        return AgentIPCResponseResult(paneList: entries)
    }

    // MARK: - Focus

    @MainActor
    private static func handleFocus(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        guard let focusTarget = arguments.first else {
            windowController.focusPane(id: target.paneID, in: target.worklaneID)
            return AgentIPCResponseResult()
        }

        switch focusTarget {
        case "left":
            windowController.handlePaneIPCCommand(.focusLeft)
        case "right":
            windowController.handlePaneIPCCommand(.focusRight)
        case "up":
            windowController.handlePaneIPCCommand(.focusUp)
        case "down":
            windowController.handlePaneIPCCommand(.focusDown)
        default:
            if let paneID = windowController.resolvePaneID(focusTarget, in: target.worklaneID) {
                windowController.focusPane(id: paneID, in: target.worklaneID)
            }
        }
        return AgentIPCResponseResult()
    }

    // MARK: - Close

    @MainActor
    private static func handleClose(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        if let closeTarget = arguments.first {
            if let paneID = windowController.resolvePaneID(closeTarget, in: target.worklaneID) {
                windowController.closePane(id: paneID)
            }
        } else {
            windowController.closePane(id: target.paneID)
        }
        return AgentIPCResponseResult()
    }

    // MARK: - Resize

    @MainActor
    private static func handleResize(
        arguments: [String],
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        guard let resizeTarget = arguments.first else {
            return AgentIPCResponseResult()
        }

        switch resizeTarget {
        case "left":
            windowController.handlePaneIPCCommand(.resizeLeft)
        case "right":
            windowController.handlePaneIPCCommand(.resizeRight)
        case "up":
            windowController.handlePaneIPCCommand(.resizeUp)
        case "down":
            windowController.handlePaneIPCCommand(.resizeDown)
        default:
            if resizeTarget.hasSuffix("%"),
               let value = Double(resizeTarget.dropLast()),
               value > 0, value <= 100 {
                let fraction = CGFloat(value / 100.0)
                windowController.resizeFocusedColumnToFraction(fraction)
            }
        }
        return AgentIPCResponseResult()
    }

    // MARK: - Layout

    @MainActor
    private static func handleLayout(
        arguments: [String],
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        guard let preset = arguments.first else {
            return AgentIPCResponseResult()
        }

        let isVertical = arguments.contains("--vertical") || arguments.contains("-v")

        switch preset {
        case "halves":
            if isVertical {
                windowController.handlePaneIPCCommand(.arrangeVertically(.twoPerColumn))
            } else {
                windowController.handlePaneIPCCommand(.arrangeHorizontally(.halfWidth))
            }
        case "thirds":
            if isVertical {
                windowController.handlePaneIPCCommand(.arrangeVertically(.threePerColumn))
            } else {
                windowController.handlePaneIPCCommand(.arrangeHorizontally(.thirds))
            }
        case "quarters":
            if isVertical {
                windowController.handlePaneIPCCommand(.arrangeVertically(.fourPerColumn))
            } else {
                windowController.handlePaneIPCCommand(.arrangeHorizontally(.quarters))
            }
        case "full":
            if isVertical {
                windowController.handlePaneIPCCommand(.arrangeVertically(.fullHeight))
            } else {
                windowController.handlePaneIPCCommand(.arrangeHorizontally(.fullWidth))
            }
        case "golden-wide":
            windowController.handlePaneIPCCommand(.arrangeGoldenRatio(.focusWide))
        case "golden-narrow":
            windowController.handlePaneIPCCommand(.arrangeGoldenRatio(.focusNarrow))
        case "golden-tall":
            windowController.handlePaneIPCCommand(.arrangeGoldenRatio(.focusTall))
        case "golden-short":
            windowController.handlePaneIPCCommand(.arrangeGoldenRatio(.focusShort))
        case "reset":
            windowController.handlePaneIPCCommand(.resetLayout)
        default:
            break
        }
        return AgentIPCResponseResult()
    }
}
