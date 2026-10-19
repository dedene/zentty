import Foundation

/// Read-side commands (list-*, display-message, has-session) and options.
extension TmuxCompatIPCHandler {
    static let defaultListPanesTemplate = "#{pane_id} #{pane_index} #{pane_title} #{?pane_active,*,-}"
    static let defaultListWindowsTemplate = "#{window_id} #{window_index} #{window_name}"
    static let defaultListSessionsTemplate = "#{session_name}: #{session_windows} windows (attached)"
    static let defaultDisplayMessageTemplate = "#{pane_id}"

    // MARK: - list-panes / list-windows / list-sessions

    @MainActor
    static func handleListPanes(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-F", "-f", "-t"], boolFlags: ["-a", "-s"])
        let template = parsed.formatTemplate ?? defaultListPanesTemplate
        let windows: [TmuxTopology.Window]
        if parsed.hasFlag("-a") {
            windows = context.topology.session.windows
        } else if parsed.hasFlag("-s") {
            guard context.resolver.matchesSession(parsed.value("-t")) else {
                throw TmuxCompatIPCError.sessionNotFound(parsed.value("-t") ?? "")
            }
            windows = context.topology.session.windows
        } else {
            windows = [try context.window(parsed.value("-t"))]
        }
        try context.requirePanePIDIfNeeded(template, panes: windows.flatMap(\.panes))

        let lines = windows.flatMap { window in
            window.panes.map { pane in
                TmuxFormatRenderer.render(
                    template,
                    context: context.formatContext(window: window, pane: pane, template: template)
                )
            }
        }
        let paneEntries = windows.count == 1
            ? context.windowController.paneListEntries(for: WorklaneID(windows[0].id))
            : nil
        return AgentIPCResponseResult(paneList: paneEntries, stdout: joinedLines(lines))
    }

    @MainActor
    static func handleListWindows(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        // Scoped to the caller's Zentty window: an agent in one window does
        // not see another window's worklanes.
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-F", "-f", "-t"], boolFlags: ["-a"])
        if !parsed.hasFlag("-a"), !context.resolver.matchesSession(parsed.value("-t")) {
            throw TmuxCompatIPCError.sessionNotFound(parsed.value("-t") ?? "")
        }
        let template = parsed.formatTemplate ?? defaultListWindowsTemplate
        let lines = context.topology.session.windows.map { window in
            TmuxFormatRenderer.render(template, context: context.formatContext(window: window))
        }
        return AgentIPCResponseResult(stdout: joinedLines(lines))
    }

    @MainActor
    static func handleListSessions(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-F", "-f"], boolFlags: [])
        let template = parsed.formatTemplate ?? defaultListSessionsTemplate
        let line = TmuxFormatRenderer.render(template, context: TmuxFormatContext.session(context.topology))
        return AgentIPCResponseResult(stdout: line + "\n")
    }

    @MainActor
    static func handleHasSession(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(arguments, valueFlags: ["-t"], boolFlags: [])
        guard context.resolver.matchesSession(parsed.value("-t")) else {
            throw TmuxCompatIPCError.sessionNotFound(parsed.value("-t") ?? "")
        }
        return AgentIPCResponseResult()
    }

    // MARK: - display-message

    @MainActor
    static func handleDisplayMessage(
        arguments: [String],
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-c", "-d", "-F", "-t"],
            boolFlags: ["-a", "-I", "-l", "-N", "-p", "-v"]
        )
        // Without `-t` tmux uses the caller's own pane (from `$TMUX_PANE`).
        let location = try context.pane(parsed.value("-t"))
        let template = parsed.displayTemplate ?? defaultDisplayMessageTemplate
        try context.requirePanePIDIfNeeded(template, panes: [location.pane])
        let variables = context.formatContext(window: location.window, pane: location.pane, template: template)

        if parsed.hasFlag("-a") {
            let lines = variables.keys.sorted().map { "\($0)=\(variables[$0] ?? "")" }
            return AgentIPCResponseResult(stdout: joinedLines(lines))
        }
        // Without `-p` tmux shows the message in the status line and prints
        // nothing; Zentty has no status line to show it in.
        guard parsed.hasFlag("-p") else {
            return AgentIPCResponseResult()
        }
        let rendered = parsed.hasFlag("-l") ? template : TmuxFormatRenderer.render(template, context: variables)
        return AgentIPCResponseResult(stdout: rendered + "\n")
    }

    // MARK: - set-option / show-options

    @MainActor
    static func handleSetOption(
        arguments: [String],
        impliedScope: String?,
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: ["-a", "-F", "-g", "-o", "-p", "-q", "-s", "-U", "-u", "-w"]
        )
        guard let name = parsed.positionals.first else {
            return AgentIPCResponseResult()
        }
        let scope = try optionScope(parsed: parsed, impliedScope: impliedScope, context: context)
        let state = TmuxCompatSessionState.shared
        if parsed.hasFlag("-u") || parsed.hasFlag("-U") {
            state.unsetOption(name, scope: scope)
            return AgentIPCResponseResult()
        }
        var value = parsed.positionals.dropFirst().joined(separator: " ")
        if parsed.hasFlag("-F") {
            let location = try context.pane(parsed.value("-t"))
            value = TmuxFormatRenderer.render(
                value,
                context: context.formatContext(window: location.window, pane: location.pane, template: value)
            )
        }
        if parsed.hasFlag("-o"), state.option(name, scope: scope) != nil {
            return AgentIPCResponseResult()
        }
        if parsed.hasFlag("-a") {
            state.appendOption(name, value: value, scope: scope)
        } else {
            state.setOption(name, value: value, scope: scope)
        }
        return AgentIPCResponseResult()
    }

    @MainActor
    static func handleShowOptions(
        arguments: [String],
        impliedScope: String?,
        context: TmuxCompatRequestContext
    ) throws -> AgentIPCResponseResult {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: ["-A", "-g", "-H", "-p", "-q", "-s", "-v", "-w"]
        )
        let scope = try optionScope(parsed: parsed, impliedScope: impliedScope, context: context)
        let state = TmuxCompatSessionState.shared
        let inherit = parsed.hasFlag("-A") || !(parsed.hasFlag("-p") || parsed.hasFlag("-w") || impliedScope != nil)
        let lookup: (String) -> String? = { name in
            if inherit {
                return state.inheritedOption(
                    name,
                    paneID: scope.paneID,
                    worklaneID: scope.worklaneID,
                    windowID: context.topology.session.id
                )
            }
            return state.option(name, scope: scope)
        }
        return AgentIPCResponseResult(stdout: showOptionsStdout(
            arguments: arguments,
            lookup: lookup,
            all: inherit ? TmuxFormatContext.defaultOptions.merging(state.options(in: scope)) { _, new in new }
                : state.options(in: scope)
        ))
    }

    /// `show-options` output. A named option prints `name value` (or only
    /// the value with `-v`); options never set fall back to tmux defaults.
    static func showOptionsStdout(
        arguments: [String],
        lookup: (String) -> String? = { _ in nil },
        all: [String: String] = TmuxFormatContext.defaultOptions
    ) -> String {
        let parsed = TmuxCompatArguments.parse(
            arguments,
            valueFlags: ["-t"],
            boolFlags: ["-A", "-g", "-H", "-p", "-q", "-s", "-v", "-w"]
        )
        guard let optionName = parsed.positionals.last, !optionName.isEmpty else {
            let lines = all.keys.sorted().map { "\($0) \(all[$0] ?? "")" }
            return joinedLines(lines)
        }
        let value = lookup(optionName) ?? TmuxFormatContext.defaultOptions[optionName]
        guard let value else {
            // Unset user options print nothing, like tmux with `-q`.
            return parsed.hasFlag("-v") || optionName.hasPrefix("@") ? "" : "\(optionName) \n"
        }
        if parsed.hasFlag("-v") {
            return value + "\n"
        }
        return "\(optionName) \(value)\n"
    }

    @MainActor
    private static func optionScope(
        parsed: TmuxCompatArguments,
        impliedScope: String?,
        context: TmuxCompatRequestContext
    ) throws -> TmuxCompatSessionState.OptionScope {
        if parsed.hasFlag("-p") {
            return .pane(try context.pane(parsed.value("-t")).pane.id)
        }
        if parsed.hasFlag("-w") || impliedScope == "-w" {
            if parsed.hasFlag("-g") {
                return .global
            }
            return .window(try context.window(parsed.value("-t")).optionsKey)
        }
        if parsed.hasFlag("-g") || parsed.hasFlag("-s") {
            return .global
        }
        if let target = parsed.value("-t"), !context.resolver.matchesSession(target) {
            throw TmuxCompatIPCError.sessionNotFound(target)
        }
        return .session(context.topology.session.id)
    }

    static func joinedLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

extension TmuxCompatSessionState.OptionScope {
    var paneID: String? {
        if case let .pane(id) = self { return id }
        return nil
    }

    var worklaneID: String? {
        if case let .window(id) = self { return id }
        return nil
    }
}
