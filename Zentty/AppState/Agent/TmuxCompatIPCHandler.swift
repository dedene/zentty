import AppKit
import Foundation
import OSLog

private let tmuxLogger = Logger(subsystem: "be.zenjoy.zentty", category: "tmux-compat")

/// Translates the small subset of tmux subcommands that Claude Code's
/// experimental agent-teams mode emits (split-window, send-keys, list-panes,
/// kill-pane, etc.) into Zentty's existing window-controller and worklane
/// operations. This keeps agent team pane operations inside Zentty's layout model.
enum TmuxCompatIPCHandler {
    static func handle(
        request: AgentIPCRequest,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let subcommand = request.subcommand?.lowercased() else {
            throw AgentIPCError.invalidMessage
        }

        tmuxLogger.debug(
            "tmux \(subcommand, privacy: .public) args=\(request.arguments.joined(separator: " "), privacy: .public)"
        )

        if subcommand == "wait-for" || subcommand == "wait" {
            trace(
                event: "ipc_wait_for",
                request: request,
                fields: ["phase": "local"]
            )
            return handleWaitFor(arguments: request.arguments, environment: request.environment)
        }

        var captured: AgentIPCResponseResult = AgentIPCResponseResult()
        var dispatchError: Error?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                do {
                    captured = try Self.dispatch(
                        subcommand: subcommand,
                        arguments: request.arguments,
                        standardInput: request.standardInput,
                        target: target
                    )
                } catch {
                    dispatchError = error
                }
            }
        }
        if let dispatchError {
            trace(
                event: "ipc_error",
                request: request,
                fields: ["error": String(describing: dispatchError)]
            )
            throw dispatchError
        }
        trace(
            event: "ipc_result",
            request: request,
            fields: [
                "stdout_bytes": "\(captured.stdout?.utf8.count ?? 0)",
                "pane_count": "\(captured.paneList?.count ?? 0)",
            ]
        )
        return captured
    }

    @MainActor
    private static func dispatch(
        subcommand: String,
        arguments: [String],
        standardInput: String?,
        target: AgentIPCTarget
    ) throws -> AgentIPCResponseResult {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            return AgentIPCResponseResult()
        }
        guard let windowController = target.windowID
            .flatMap(appDelegate.windowController(with:))
            ?? appDelegate.windowController(containingWorklane: target.worklaneID)
        else {
            return AgentIPCResponseResult()
        }

        switch subcommand {
        case "split-window", "splitw":
            return handleSplitWindow(arguments: arguments, target: target, windowController: windowController)
        case "send-keys", "send":
            return handleSendKeys(
                arguments: arguments,
                standardInput: standardInput,
                target: target,
                windowController: windowController
            )
        case "select-pane", "selectp":
            return handleSelectPane(arguments: arguments, target: target, windowController: windowController)
        case "select-window", "selectw":
            // Worklane already focused via routing; nothing more to do.
            return AgentIPCResponseResult()
        case "kill-pane", "killp":
            return handleKillPane(arguments: arguments, target: target, windowController: windowController)
        case "kill-window", "killw":
            return handleKillWindow(target: target, windowController: windowController)
        case "list-panes", "lsp":
            return handleListPanes(arguments: arguments, target: target, windowController: windowController)
        case "list-windows", "lsw":
            return handleListWindows(arguments: arguments, target: target, windowController: windowController)
        case "display-message", "display":
            return handleDisplayMessage(
                arguments: arguments,
                target: target,
                windowController: windowController
            )
        case "rename-window", "renamew":
            return AgentIPCResponseResult()
        case "select-layout", "selectl":
            return handleSelectLayout(arguments: arguments, target: target, windowController: windowController)
        case "resize-pane", "resizep":
            return handleResizePane(arguments: arguments, target: target, windowController: windowController)
        case "new-session", "new":
            return handleNewSession(arguments: arguments, target: target)
        case "new-window", "neww":
            return AgentIPCResponseResult()
        case "wait-for", "wait":
            return handleWaitFor(arguments: arguments, environment: targetEnvironment(target))
        case "show", "show-options", "show-option", "showw", "show-window-options":
            return handleShowOptions(arguments: arguments)
        case "last-pane", "lastp":
            return AgentIPCResponseResult()
        case "save-buffer", "saveb":
            return handleSaveBuffer(arguments: arguments)
        case "show-buffer", "showb":
            return handleShowBuffer(arguments: arguments)
        case "set-buffer", "setb":
            return handleSetBuffer(arguments: arguments, standardInput: standardInput)
        case "load-buffer", "loadb":
            return handleLoadBuffer(arguments: arguments, standardInput: standardInput)
        case "capture-pane", "capturep":
            return handleCapturePane(arguments: arguments, target: target, windowController: windowController)
        case "popup":
            throw AgentIPCError.unsupportedSubcommand("popup")
        default:
            tmuxLogger.debug("Ignoring unsupported tmux subcommand: \(subcommand, privacy: .public)")
            return AgentIPCResponseResult()
        }
    }

    // MARK: - split-window

    @MainActor
    private static func handleSplitWindow(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-c", "-F", "-l", "-t"],
            boolFlags: ["-P", "-b", "-d", "-h", "-v"]
        )
        let key = target.worklaneID.rawValue
        let preExisting = TmuxCompatStoreIO.load().anchors[key]
        let startupRequest = splitWindowStartupRequest(parsed: parsed)
        let newPaneID: String?

        // Snapshot the leader's column width BEFORE any split-window layout
        // disruption, but only on the team's first split (preExisting == nil).
        // Restored when the last subagent is killed so the pre-team layout
        // returns even when other columns existed alongside the leader.
        let preTeamLeaderColumnWidth: CGFloat? = preExisting == nil
            ? windowController.columnWidthForPane(id: target.paneID, in: target.worklaneID)
            : nil

        if preExisting == nil {
            // First subagent for this worklane: create a new column to the
            // right of the leader at golden ratio while keeping the leader
            // visually anchored.
            newPaneID = windowController.splitWithLayout(
                placement: .afterFocused,
                isHorizontal: true,
                layout: .golden,
                targetPaneID: target.paneID,
                preserveFocusPaneID: target.paneID,
                sessionRequest: startupRequest
            )?.rawValue
        } else {
            // Subsequent subagent: stack vertically inside the existing
            // subagent column without moving the user's focus away from the
            // leader pane.
            let targetPaneID = preExisting?.columnPaneIDs.last.map { PaneID($0) } ?? target.paneID
            let preservePaneID = PaneID(preExisting?.leaderPaneID ?? target.paneID.rawValue)
            newPaneID = windowController.splitWithLayout(
                placement: .afterFocused,
                isHorizontal: false,
                layout: .equal,
                targetPaneID: targetPaneID,
                preserveFocusPaneID: preservePaneID,
                sessionRequest: startupRequest
            )?.rawValue
        }

        TmuxCompatStoreIO.mutate { store in
            if var updatedAnchor = store.anchors[key] {
                if let newPaneID {
                    updatedAnchor.columnPaneIDs.append(newPaneID)
                }
                store.anchors[key] = updatedAnchor
            } else {
                store.anchors[key] = WorklaneAnchor(
                    leaderPaneID: target.paneID.rawValue,
                    columnPaneIDs: newPaneID.map { [$0] } ?? [],
                    preTeamLeaderColumnWidth: preTeamLeaderColumnWidth
                )
            }
            if !parsed.hasFlag("-d"), let newPaneID {
                store.activePaneIDs[key] = newPaneID
            }
        }
        windowController.refreshTeamAnchors()
        if newPaneID != nil {
            let leaderPaneID = preExisting?.leaderPaneID ?? target.paneID.rawValue
            windowController.resizeColumnContainingPane(
                id: PaneID(leaderPaneID),
                toFraction: goldenWideFraction
            )
        }

        guard let newPaneID else {
            return AgentIPCResponseResult()
        }
        guard parsed.hasFlag("-P") else {
            return AgentIPCResponseResult()
        }
        let template = parsed.formatTemplate ?? "#{pane_id}"
        let window = windowCoordinates(for: target.worklaneID, windowController: windowController)
        let context = windowController
            .paneListEntries(for: target.worklaneID)
            .first(where: { $0.id == newPaneID })
            .map { paneContext(for: $0, windowID: window.id, windowIndex: window.index) }
            ?? [
                "pane_id": "%\(newPaneID)",
                "pane_uuid": newPaneID,
                "window_id": "@\(window.id)",
                "window_index": String(window.index),
                "session_name": "zentty",
            ]
        return AgentIPCResponseResult(
            stdout: TmuxFormatRenderer.render(template, context: context) + "\n"
        )
    }

    // MARK: - send-keys

    @MainActor
    private static func handleSendKeys(
        arguments: [String],
        standardInput: String?,
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let resolvedPaneID = resolvedTargetPaneID(
            arguments: arguments,
            target: target,
            windowController: windowController
        )
        let text = sendKeysText(arguments: arguments, standardInput: standardInput)
        guard !text.isEmpty else {
            return AgentIPCResponseResult()
        }
        if let launchCommand = launchCommandFromSendKeysText(text),
           let nativeCommand = shellWrappedGhosttyCommand(launchCommand),
           windowController.launchDeferredPane(id: resolvedPaneID, nativeCommand: nativeCommand) {
            return AgentIPCResponseResult()
        }
        let delivered = windowController.sendText(text, to: resolvedPaneID)
        if !delivered {
            tmuxLogger.warning(
                "send-keys: no live runtime for pane \(resolvedPaneID.rawValue, privacy: .public)"
            )
        }
        return AgentIPCResponseResult()
    }

    static func sendKeysText(arguments: [String], standardInput: String?) -> String {
        // Filter out tmux flags. `-t target` and `-l` and `-R` and friends
        // are handled by the caller resolution above.
        var skipNext = false
        var pieces: [String] = []
        var literal = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "-t" || argument == "-T" || argument == "-N" {
                skipNext = true
                continue
            }
            if argument == "-l" {
                literal = true
                continue
            }
            if argument.hasPrefix("-") {
                continue
            }
            pieces.append(argument)
        }
        let joined = tmuxSendKeysText(tokens: pieces, literal: literal)
        if !joined.isEmpty {
            return joined
        }
        return standardInput ?? ""
    }

    static func launchCommandFromSendKeysText(_ text: String) -> String? {
        guard text.hasSuffix("\r") || text.hasSuffix("\n") else {
            return nil
        }
        let command = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              !command.contains("\r"),
              !command.contains("\n")
        else {
            return nil
        }
        return command
    }

    static func shellWrappedGhosttyCommand(
        _ command: String,
        loginShellPath: String? = ProcessInfo.processInfo.environment["SHELL"]
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let shellPath = loginShellPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shellPath.isEmpty,
           isLoginShellSupported(shellPath) {
            return "\(shellQuote(shellPath)) -lic \(shellQuote(trimmed))"
        }
        return "sh -c \(shellQuote(trimmed))"
    }

    private static func isLoginShellSupported(_ shellPath: String) -> Bool {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        return shellName == "zsh" || shellName == "bash" || shellName == "fish"
    }

    private static func splitWindowStartupRequest(parsed: TmuxCompatArguments) -> TerminalSessionRequest {
        let commandText = parsed.positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let nativeCommand = shellWrappedGhosttyCommand(commandText) {
            return TerminalSessionRequest(
                workingDirectory: parsed.value("-c"),
                nativeCommand: nativeCommand,
                waitAfterNativeCommand: true
            )
        }

        return TerminalSessionRequest(
            workingDirectory: parsed.value("-c"),
            isLaunchDeferred: true
        )
    }

    private static func tmuxSendKeysText(tokens: [String], literal: Bool) -> String {
        if literal {
            return tokens.joined(separator: " ")
        }

        var result = ""
        var pendingSpace = false
        for token in tokens {
            if let special = tmuxSpecialKeyText(token) {
                result += special
                pendingSpace = false
                continue
            }
            if pendingSpace {
                result += " "
            }
            result += token
            pendingSpace = true
        }
        return result
    }

    private static func tmuxSpecialKeyText(_ token: String) -> String? {
        switch token.lowercased() {
        case "enter", "c-m", "kpenter":
            return "\r"
        case "tab", "c-i":
            return "\t"
        case "space":
            return " "
        case "bspace", "backspace":
            return "\u{7f}"
        case "escape", "esc", "c-[":
            return "\u{1b}"
        case "c-c":
            return "\u{03}"
        case "c-d":
            return "\u{04}"
        case "c-z":
            return "\u{1a}"
        case "c-l":
            return "\u{0c}"
        default:
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - select-pane

    @MainActor
    private static func handleSelectPane(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t", "-T"],
            boolFlags: ["-P"]
        )
        let paneID = resolvedTargetPaneID(
            arguments: arguments,
            target: target,
            windowController: windowController
        )
        TmuxCompatStoreIO.mutate { store in
            store.activePaneIDs[target.worklaneID.rawValue] = paneID.rawValue
        }
        if let title = parsed.value("-T") {
            windowController.setPaneTitle(id: paneID, title: title)
        }
        return AgentIPCResponseResult()
    }

    // MARK: - kill-pane / kill-window

    @MainActor
    private static func handleKillPane(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        // `WorklaneStore.closePane(id:)` already runs `cascadeCloseTeamColumnIfLeader`
        // which prunes the anchor when the leader is closed. Subagent panes
        // need their column-membership pruned here.
        let key = target.worklaneID.rawValue
        let paneEntries = windowController.paneListEntries(for: target.worklaneID)
        let hasExplicitTarget = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: []
        ).value("-t") != nil
        guard let paneID = explicitTargetPaneID(arguments: arguments, paneEntries: paneEntries)
            ?? (hasExplicitTarget ? nil : target.paneID) else {
            return AgentIPCResponseResult()
        }
        // When the last subagent is torn down we want to restore the leader's
        // pre-team column width. Capture the snapshot + leader id before the
        // mutation drops the anchor so we can apply the resize after the
        // pane close lands in the layout.
        var dissolvedTeamLeader: (paneID: PaneID, snapshotWidth: CGFloat)?
        TmuxCompatStoreIO.mutate { store in
            if var anchor = store.anchors[key],
               anchor.leaderPaneID != paneID.rawValue {
                anchor.columnPaneIDs.removeAll(where: { $0 == paneID.rawValue })
                if anchor.columnPaneIDs.isEmpty {
                    // Last subagent torn down — the team is dissolved. Drop
                    // the anchor so the leader's ✳ marker disappears even if
                    // Claude Code keeps running for further user prompts.
                    if let snapshot = anchor.preTeamLeaderColumnWidth {
                        dissolvedTeamLeader = (PaneID(anchor.leaderPaneID), snapshot)
                    }
                    store.anchors.removeValue(forKey: key)
                } else {
                    store.anchors[key] = anchor
                }
            }
            if store.activePaneIDs[key] == paneID.rawValue {
                store.activePaneIDs.removeValue(forKey: key)
            }
        }
        windowController.closePane(id: paneID)
        windowController.refreshTeamAnchors()
        if let dissolved = dissolvedTeamLeader {
            windowController.resizeColumnContainingPaneToWidth(
                id: dissolved.paneID,
                width: dissolved.snapshotWidth
            )
        }
        return AgentIPCResponseResult()
    }

    @MainActor
    private static func handleKillWindow(
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        // Closing the leader pane is enough — `WorklaneStore.closePane` will
        // cascade-close the recorded subagent column and drop the anchor.
        // If there's no anchor, just close the targeted pane (the worklane
        // itself disappears via the standard close path).
        let key = target.worklaneID.rawValue
        let leaderPaneID = TmuxCompatStoreIO.load().anchors[key].map { PaneID($0.leaderPaneID) }
        TmuxCompatStoreIO.mutate { store in
            store.activePaneIDs.removeValue(forKey: key)
        }
        windowController.closePane(id: leaderPaneID ?? target.paneID)
        windowController.refreshTeamAnchors()
        return AgentIPCResponseResult()
    }

    // MARK: - list-panes / list-windows / display-message

    @MainActor
    private static func handleListPanes(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let entries = windowController.paneListEntries(for: target.worklaneID)
        let activePaneID = TmuxCompatStoreIO.load().activePaneIDs[target.worklaneID.rawValue]
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-F", "-t"],
            boolFlags: []
        )
        let template = parsed.formatTemplate ?? defaultListPanesTemplate
        let window = windowCoordinates(for: target.worklaneID, windowController: windowController)
        let lines = entries.map { entry in
            TmuxFormatRenderer.render(
                template,
                context: paneContext(
                    for: entry,
                    windowID: window.id,
                    windowIndex: window.index,
                    activePaneID: activePaneID
                )
            )
        }
        return AgentIPCResponseResult(
            paneList: entries,
            stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        )
    }

    @MainActor
    private static func handleListWindows(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        // Scope to the calling window only — Claude inside one Zentty window
        // shouldn't see worklane IDs from other windows.
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-F", "-t"],
            boolFlags: []
        )
        let template = parsed.formatTemplate ?? defaultListWindowsTemplate
        let lines = windowController.discoveryWorkspaceState.worklanes
            .enumerated()
            .map { worklaneIndex, worklane in
                TmuxFormatRenderer.render(template, context: [
                    "session_name": "zentty",
                    "window_id": "@\(worklane.id.rawValue)",
                    "window_uuid": worklane.id.rawValue,
                    "window_index": String(worklaneIndex),
                    "window_name": worklane.title.isEmpty ? "worklane-\(worklaneIndex)" : worklane.title,
                ])
            }
        return AgentIPCResponseResult(stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
    }

    @MainActor
    private static func handleDisplayMessage(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-F", "-t"],
            boolFlags: ["-p"]
        )
        let template = parsed.displayTemplate ?? defaultDisplayMessageTemplate
        let entries = windowController.paneListEntries(for: target.worklaneID)
        let activePaneID = TmuxCompatStoreIO.load().activePaneIDs[target.worklaneID.rawValue]
        let targetPaneID = parsed.value("-t").flatMap {
            resolvedPaneID(from: $0, in: target.worklaneID, windowController: windowController)
        }
        guard let entry = targetPaneID.flatMap({ paneID in
            entries.first(where: { $0.id == paneID.rawValue })
        })
            ?? activePaneID.flatMap({ activeID in entries.first(where: { $0.id == activeID }) })
            ?? entries.first(where: { $0.id == target.paneID.rawValue })
            ?? entries.first(where: { $0.isFocused })
            ?? entries.first
        else {
            return AgentIPCResponseResult(stdout: "")
        }
        let window = windowCoordinates(for: target.worklaneID, windowController: windowController)
        let rendered = TmuxFormatRenderer.render(
            template,
            context: paneContext(
                for: entry,
                windowID: window.id,
                windowIndex: window.index,
                activePaneID: activePaneID
            )
        )
        return AgentIPCResponseResult(stdout: rendered + "\n")
    }

    // MARK: - select-layout

    @MainActor
    private static func handleSelectLayout(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        // Claude only ever emits `main-vertical` for agent teams. Equalize
        // the column heights to redistribute space among subagents.
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: []
        )
        let preset = parsed.positionals.first ?? "main-vertical"
        if preset == "main-vertical" || preset == "even-vertical" {
            windowController.equalizeFocusedColumnPaneHeights()
            if preset == "main-vertical",
               let leaderPaneID = TmuxCompatStoreIO.load().anchors[target.worklaneID.rawValue]?.leaderPaneID {
                windowController.resizeColumnContainingPane(
                    id: PaneID(leaderPaneID),
                    toFraction: goldenWideFraction
                )
            }
        }
        return AgentIPCResponseResult()
    }

    @MainActor
    private static func handleResizePane(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t", "-x", "-y"],
            boolFlags: ["-D", "-L", "-R", "-U"]
        )
        guard let width = parsed.value("-x"),
              width.hasSuffix("%"),
              let anchor = TmuxCompatStoreIO.load().anchors[target.worklaneID.rawValue] else {
            return AgentIPCResponseResult()
        }

        // Claude emits `resize-pane -x 30%` after `main-vertical`. Keep the
        // leader/teammate split at Zentty's golden ratio instead of applying
        // Claude's exact tmux width hint.
        windowController.resizeColumnContainingPane(
            id: PaneID(anchor.leaderPaneID),
            toFraction: goldenWideFraction
        )
        return AgentIPCResponseResult()
    }

    private static var goldenWideFraction: CGFloat {
        let phi = (1 + sqrt(CGFloat(5))) / 2
        return phi / (1 + phi)
    }

    // MARK: - new-session

    @MainActor
    private static func handleNewSession(
        arguments: [String],
        target: AgentIPCTarget
    ) -> AgentIPCResponseResult {
        if arguments.contains("-A") {
            tmuxLogger.warning("new-session -A is not supported in zentty agent-teams mode")
        }
        return AgentIPCResponseResult(stdout: "@\(target.worklaneID.rawValue)\n")
    }

    // MARK: - buffers

    static func showOptionsStdout(arguments: [String]) -> String {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: ["-A", "-g", "-v", "-w"]
        )
        let optionName = parsed.positionals.last ?? ""
        guard !optionName.isEmpty else {
            return ""
        }
        let value = tmuxOptionValue(optionName)
        if parsed.hasFlag("-v") {
            return value + "\n"
        }
        return "\(optionName) \(value)\n"
    }

    private static func handleShowOptions(arguments: [String]) -> AgentIPCResponseResult {
        AgentIPCResponseResult(stdout: showOptionsStdout(arguments: arguments))
    }

    private static func tmuxOptionValue(_ name: String) -> String {
        switch name {
        case "focus-events", "mouse", "synchronize-panes":
            return "off"
        default:
            return ""
        }
    }

    private static func handleSaveBuffer(arguments: [String]) -> AgentIPCResponseResult {
        let store = TmuxCompatStoreIO.load()
        let bufferName = bufferName(in: arguments) ?? store.buffers.keys.sorted().first ?? ""
        let value = store.buffers[bufferName] ?? ""
        return AgentIPCResponseResult(stdout: value)
    }

    private static func handleShowBuffer(arguments: [String]) -> AgentIPCResponseResult {
        handleSaveBuffer(arguments: arguments)
    }

    private static func handleSetBuffer(
        arguments: [String],
        standardInput: String?
    ) -> AgentIPCResponseResult {
        let bufferName = bufferName(in: arguments) ?? "default"
        let value = standardInput ?? ""
        TmuxCompatStoreIO.mutate { store in
            store.buffers[bufferName] = value
        }
        return AgentIPCResponseResult()
    }

    private static func handleLoadBuffer(
        arguments: [String],
        standardInput: String?
    ) -> AgentIPCResponseResult {
        handleSetBuffer(arguments: arguments, standardInput: standardInput)
    }

    // MARK: - capture-pane

    struct CapturePaneOptions: Equatable {
        let target: String?
        let print: Bool
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    @MainActor
    private static func handleCapturePane(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> AgentIPCResponseResult {
        let options = capturePaneOptions(arguments: arguments)
        let paneID = options.target
            .flatMap { resolvedPaneID(from: $0, in: target.worklaneID, windowController: windowController) }
            ?? target.paneID
        let text = windowController.readText(
            from: paneID,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        ) ?? ""

        if options.print {
            return AgentIPCResponseResult(stdout: text.hasSuffix("\n") ? text : text + "\n")
        }

        TmuxCompatStoreIO.mutate { store in
            store.buffers["default"] = text
        }
        return AgentIPCResponseResult()
    }

    static func capturePaneOptions(arguments: [String]) -> CapturePaneOptions {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-E", "-S", "-t"],
            boolFlags: ["-J", "-N", "-p"]
        )
        let lineLimit = parsed.value("-S").flatMap { value -> Int? in
            guard let start = Int(value), start < 0 else {
                return nil
            }
            return abs(start)
        }
        return CapturePaneOptions(
            target: parsed.value("-t"),
            print: parsed.hasFlag("-p"),
            includeScrollback: true,
            lineLimit: lineLimit
        )
    }

    // MARK: - wait-for

    enum WaitForAction: Equatable {
        case signal(String)
        case wait(name: String, timeout: TimeInterval)
        case invalid
    }

    private static func handleWaitFor(
        arguments: [String],
        environment: [String: String]
    ) -> AgentIPCResponseResult {
        switch waitForAction(arguments: arguments) {
        case .signal(let name):
            signalWaitFor(name: name, environment: environment)
        case .wait(let name, let timeout):
            _ = waitForSignal(name: name, timeout: timeout, environment: environment)
        case .invalid:
            tmuxLogger.warning("wait-for requires a name")
        }
        return AgentIPCResponseResult()
    }

    static func waitForAction(arguments: [String]) -> WaitForAction {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["--timeout"],
            boolFlags: ["-S", "--signal"]
        )
        guard let name = parsed.positionals.first else {
            return .invalid
        }
        if parsed.hasFlag("-S") || parsed.hasFlag("--signal") {
            return .signal(name)
        }
        let timeout = parsed.value("--timeout").flatMap(TimeInterval.init) ?? 30
        return .wait(name: name, timeout: timeout)
    }

    static func waitForSignalURL(name: String, environment: [String: String] = [:]) -> URL {
        let scope = environment["ZENTTY_INSTANCE_ID"] ?? environment["ZENTTY_WORKLANE_ID"] ?? "global"
        let rawName = "\(scope)-\(name)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = rawName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return URL(fileURLWithPath: "/tmp/zentty-tmux-wait-for-\(String(sanitized)).sig")
    }

    static func signalWaitFor(name: String, environment: [String: String] = [:]) {
        let url = waitForSignalURL(name: name, environment: environment)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    static func waitForSignal(
        name: String,
        timeout: TimeInterval,
        environment: [String: String] = [:]
    ) -> Bool {
        let url = waitForSignalURL(name: name, environment: environment)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        return false
    }

    // MARK: - helpers

    @MainActor
    private static func resolvedTargetPaneID(
        arguments: [String],
        target: AgentIPCTarget,
        windowController: MainWindowController
    ) -> PaneID {
        resolvedTargetPaneID(
            arguments: arguments,
            fallback: target.paneID,
            paneEntries: windowController.paneListEntries(for: target.worklaneID)
        )
    }

    static func resolvedTargetPaneID(
        arguments: [String],
        fallback: PaneID,
        paneEntries: [PaneListEntry]
    ) -> PaneID {
        explicitTargetPaneID(arguments: arguments, paneEntries: paneEntries) ?? fallback
    }

    static func explicitTargetPaneID(
        arguments: [String],
        paneEntries: [PaneListEntry]
    ) -> PaneID? {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: []
        )
        if let selector = parsed.value("-t") {
            let normalized = selector.hasPrefix("%") ? String(selector.dropFirst()) : selector
            if paneEntries.contains(where: { $0.id == normalized }) {
                return PaneID(normalized)
            }
        }
        return nil
    }

    @MainActor
    private static func resolvedPaneID(
        from selector: String,
        in worklaneID: WorklaneID,
        windowController: MainWindowController
    ) -> PaneID? {
        let normalized = selector.hasPrefix("%") ? String(selector.dropFirst()) : selector
        return windowController.resolvePaneID(normalized, in: worklaneID)
    }

    private static func bufferName(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "-b"),
              flagIndex + 1 < arguments.count
        else {
            return nil
        }
        return arguments[flagIndex + 1]
    }

    /// Builds the format-render context for a single pane.
    ///
    /// `windowID` and `windowIndex` identify the worklane the pane belongs to,
    /// using the same enumeration `list-windows` reports. Earlier revisions
    /// derived these from the pane's column-within-worklane (`entry.column`),
    /// which collided with `list-windows`'s worklane-enumeration index and
    /// broke the harness's pane→window reconciliation.
    static func paneContext(
        for entry: PaneListEntry,
        windowID: String,
        windowIndex: Int,
        activePaneID: String? = nil
    ) -> [String: String] {
        let isActive = activePaneID.map { $0 == entry.id } ?? entry.isFocused
        return [
            "session_name": "zentty",
            "pane_id": "%\(entry.id)",
            "pane_uuid": entry.id,
            "pane_index": String(entry.index),
            "pane_title": entry.title,
            "pane_active": isActive ? "1" : "",
            "pane_current_path": entry.workingDirectory ?? "",
            "window_id": "@\(windowID)",
            "window_index": String(windowIndex),
        ]
    }

    @MainActor
    private static func windowCoordinates(
        for worklaneID: WorklaneID,
        windowController: MainWindowController
    ) -> (id: String, index: Int) {
        let worklanes = windowController.discoveryWorkspaceState.worklanes
        let index = worklanes.firstIndex(where: { $0.id == worklaneID }) ?? 0
        return (id: worklaneID.rawValue, index: index)
    }

    static func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else {
            return ""
        }
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }
        var output = lines.suffix(maxLines).joined(separator: "\n")
        if hadTrailingNewline, !output.isEmpty {
            output.append("\n")
        }
        return output
    }

    private static func targetEnvironment(_ target: AgentIPCTarget) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WORKLANE_ID": target.worklaneID.rawValue,
            "ZENTTY_PANE_ID": target.paneID.rawValue,
        ]
        if let windowID = target.windowID {
            environment["ZENTTY_WINDOW_ID"] = windowID.rawValue
        }
        return environment
    }

    private static let defaultListPanesTemplate = "#{pane_id} #{pane_index} #{pane_title} #{?pane_active,*,-}"
    private static let defaultListWindowsTemplate = "#{window_id} #{window_index} #{window_name}"
    private static let defaultDisplayMessageTemplate = "#{pane_id}"

    private static func trace(
        event: String,
        request: AgentIPCRequest,
        fields: [String: String]
    ) {
        guard let path = request.environment["ZENTTY_TMUX_COMPAT_TRACE_PATH"], !path.isEmpty else {
            return
        }

        var payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "event": event,
            "subcommand": request.subcommand ?? "",
            "arguments": request.arguments,
            "worklane_id": request.environment["ZENTTY_WORKLANE_ID"] ?? "",
            "pane_id": request.environment["ZENTTY_PANE_ID"] ?? "",
        ]
        fields.forEach { payload[$0.key] = $0.value }
        appendTracePayload(payload, to: path)
    }

    private static func appendTracePayload(_ payload: [String: Any], to path: String) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return
        }

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: url) else {
            var line = data
            line.append(UInt8(ascii: "\n"))
            try? line.write(to: url, options: .atomic)
            return
        }
        defer {
            try? handle.close()
        }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
    }
}
