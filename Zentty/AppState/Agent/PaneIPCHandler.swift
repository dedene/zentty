import AppKit
import Foundation

enum PaneIPCSubcommand: String {
    case split
    case list
    case focus
    case close
    case zoom
    case resize
    case layout
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

        var result: Result<AgentIPCResponseResult, Error>!
        DispatchQueue.main.sync {
            result = .success(MainActor.assumeIsolated {
                Self.dispatch(subcommand: subcommand, request: request, target: target)
            })
        }
        return try result.get()
    }

    @MainActor
    private static func dispatch(
        subcommand: PaneIPCSubcommand,
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let windowController = target.windowID.flatMap(appDelegate.windowController(with:))
                ?? appDelegate.windowController(containingWorklane: target.worklaneID) else {
            return AgentIPCResponseResult()
        }

        if subcommand != .list {
            windowController.focusPane(id: target.paneID, in: target.worklaneID)
        }

        switch subcommand {
        case .split:
            return handleSplit(arguments: request.arguments, windowController: windowController)
        case .list:
            return handleList(target: target, windowController: windowController)
        case .focus:
            return handleFocus(arguments: request.arguments, target: target, windowController: windowController)
        case .close:
            return handleClose(arguments: request.arguments, target: target, windowController: windowController)
        case .zoom:
            return handleZoom(windowController: windowController)
        case .resize:
            return handleResize(arguments: request.arguments, windowController: windowController)
        case .layout:
            return handleLayout(arguments: request.arguments, windowController: windowController)
        }
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

    // MARK: - Zoom

    @MainActor
    private static func handleZoom(
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        windowController.handlePaneIPCCommand(.toggleZoomOut)
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
