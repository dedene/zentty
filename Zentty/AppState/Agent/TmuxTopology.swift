import Foundation

/// A tmux-shaped snapshot of one Zentty window: the window is the tmux
/// session, each worklane is a tmux window, each pane a tmux pane. Panes a
/// `new-window` call made form a window of their own inside their worklane
/// (a pane group). Built on the main actor by the IPC handler; everything
/// here is pure so target resolution and format contexts are testable
/// without AppKit.
struct TmuxTopology: Equatable {
    struct Pane: Equatable {
        var id: String
        var number: Int
        /// 0-based position inside the window, tmux's default `pane-base-index`.
        var index: Int
        var title: String
        var workingDirectory: String?
        var isActive: Bool
        var pid: Int32?
        var columns: Int
        var rows: Int
        var left: Int
        var top: Int
        var startCommand: String
        var isLaunchDeferred: Bool
    }

    struct Window: Equatable {
        /// The worklane id. A pane group's window shares it with the
        /// worklane's own window; `number` tells them apart.
        var id: String
        var number: Int
        var index: Int
        var name: String
        var isActive: Bool
        var panes: [Pane]
        var columns: Int
        var rows: Int
        /// Set for a pane group's window (see `TmuxCompatSessionState`).
        var groupKey: String? = nil

        /// Key for window-scoped options (`set-option -w`): a pane group's
        /// window has options of its own.
        var optionsKey: String {
            groupKey ?? id
        }

        var activePane: Pane? {
            panes.first(where: \.isActive) ?? panes.first
        }
    }

    struct Session: Equatable {
        var id: String
        var number: Int
        var name: String
        var created: Int
        var windows: [Window]
    }

    var session: Session
    var socketPath: String
    var serverPID: Int32

    var allPanes: [(window: Window, pane: Pane)] {
        session.windows.flatMap { window in window.panes.map { (window, $0) } }
    }

    func location(ofPane paneID: String) -> (window: Window, pane: Pane)? {
        allPanes.first(where: { $0.pane.id == paneID })
    }

    /// Splits one worklane's window into the worklane's own panes and one
    /// window per pane group, in first-pane order. Pane indexes count within
    /// each window like tmux; group windows take indexes from
    /// `nextGroupIndex`, after every worklane. A window without an active
    /// pane falls back to `focusedPaneID` when it holds it.
    static func splittingPaneGroups(
        _ worklane: Window,
        focusedPaneID: String?,
        groupOf: (String) -> String?,
        groupNumber: (String) -> Int,
        nextGroupIndex: inout Int
    ) -> (worklane: Window, groups: [Window]) {
        var ownPanes: [Pane] = []
        var groupOrder: [String] = []
        var groupPanes: [String: [Pane]] = [:]
        for pane in worklane.panes {
            if let group = groupOf(pane.id) {
                if groupPanes[group] == nil {
                    groupOrder.append(group)
                }
                groupPanes[group, default: []].append(pane)
            } else {
                ownPanes.append(pane)
            }
        }

        func reindexed(_ panes: [Pane]) -> [Pane] {
            var panes = panes.enumerated().map { offset, pane in
                var pane = pane
                pane.index = offset
                return pane
            }
            if !panes.contains(where: \.isActive),
               let focused = panes.firstIndex(where: { $0.id == focusedPaneID }) {
                panes[focused].isActive = true
            }
            return panes
        }

        var own = worklane
        own.panes = reindexed(ownPanes)
        let groups = groupOrder.map { group -> Window in
            let panes = reindexed(groupPanes[group] ?? [])
            var window = worklane
            window.number = groupNumber(group)
            window.index = nextGroupIndex
            nextGroupIndex += 1
            window.name = panes.first.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? worklane.name
            window.isActive = false
            window.panes = panes
            window.groupKey = group
            return window
        }
        return (own, groups)
    }
}

/// Resolves tmux `-t` targets against a `TmuxTopology`.
///
/// Accepted forms: `%N` pane ids (and the raw Zentty pane id, with or without
/// `%`), `@N` window ids, `$N` session ids, and the `session:window.pane`
/// grammar where each part may be empty, a `=name` exact match, an index, or
/// a name. A bare pane target is tried as a pane index in the caller's
/// window first; then, for pane and window targets alike, as the session
/// name, a window, then a name prefix. `{...}` tokens mean the
/// caller's pane. A request whose caller pane is gone resolves no default
/// target, so it cannot act on someone else's pane by accident.
struct TmuxTargetResolver {
    struct Resolution: Equatable {
        var window: TmuxTopology.Window
        var pane: TmuxTopology.Pane?
    }

    let topology: TmuxTopology
    let callerPaneID: String

    private var callerLocation: (window: TmuxTopology.Window, pane: TmuxTopology.Pane)? {
        topology.location(ofPane: callerPaneID)
    }

    /// Resolves a pane target. `nil` / empty means the caller's pane.
    func pane(_ target: String?) -> (window: TmuxTopology.Window, pane: TmuxTopology.Pane)? {
        guard let resolution = resolve(target, allowsPaneIndex: true) else {
            return nil
        }
        guard let pane = resolution.pane ?? resolution.window.activePane else {
            return nil
        }
        return (resolution.window, pane)
    }

    /// Resolves a window target to the window, ignoring any pane part.
    func window(_ target: String?) -> TmuxTopology.Window? {
        resolve(target, allowsPaneIndex: false)?.window
    }

    /// True when the target names the topology's session (`-t name`, `=name`,
    /// `$N`, or a target whose session part is empty).
    func matchesSession(_ target: String?) -> Bool {
        guard let target = target?.trimmingCharacters(in: .whitespaces), !target.isEmpty else {
            return true
        }
        let sessionPart = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target
        if sessionPart.isEmpty {
            return true
        }
        if target.hasPrefix("%") || target.hasPrefix("@") {
            return resolve(target, allowsPaneIndex: true) != nil
        }
        return sessionMatches(sessionPart)
    }

    func resolve(_ target: String?, allowsPaneIndex: Bool = true) -> Resolution? {
        guard let raw = target?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return callerResolution()
        }
        if raw.hasPrefix("{") || raw == "!" || raw == "." {
            return callerResolution()
        }
        if raw.hasPrefix("%") {
            return paneByID(String(raw.dropFirst()))
        }
        if let byRawID = paneByRawID(raw) {
            return byRawID
        }
        if raw.hasPrefix("@"), !raw.contains(".") {
            return windowByID(String(raw.dropFirst())).map { Resolution(window: $0, pane: nil) }
        }

        if let colon = raw.firstIndex(of: ":") {
            let sessionPart = String(raw[..<colon])
            guard sessionPart.isEmpty || sessionMatches(sessionPart) else {
                return nil
            }
            return resolveWindowAndPane(String(raw[raw.index(after: colon)...]))
        }
        if raw.contains(".") {
            return resolveWindowAndPane(raw)
        }

        // Bare word. Only a pane target reads a number as a pane index in
        // the caller's window; `kill-window -t 1` means window 1.
        if allowsPaneIndex, let current = callerLocation?.window, let index = Int(raw),
           let pane = current.panes.first(where: { $0.index == index }) {
            return Resolution(window: current, pane: pane)
        }
        // The session name is Zentty's own and is what tools build targets
        // from (`#{session_name}`), so it wins over a worklane that happens
        // to share or start with it.
        if sessionMatches(raw, allowsPrefix: false) {
            return sessionCurrentWindow().map { Resolution(window: $0, pane: nil) }
        }
        if let window = windowMatching(raw, allowsPrefix: false) {
            return Resolution(window: window, pane: nil)
        }
        if let window = windowMatching(raw, allowsPrefix: true) {
            return Resolution(window: window, pane: nil)
        }
        if sessionMatches(raw) {
            return sessionCurrentWindow().map { Resolution(window: $0, pane: nil) }
        }
        return nil
    }

    /// The caller's own pane. Nil when the caller is not in the topology
    /// (its pane closed or was replaced): defaulting to another pane would
    /// make `split-window` or `kill-pane` act on whatever pane is active.
    private func callerResolution() -> Resolution? {
        callerLocation.map { Resolution(window: $0.window, pane: $0.pane) }
    }

    /// The window a session target stands for: the caller's, or the
    /// active worklane's when the caller is unknown.
    private func sessionCurrentWindow() -> TmuxTopology.Window? {
        if let location = callerLocation {
            return location.window
        }
        let windows = topology.session.windows
        return windows.first(where: \.isActive) ?? windows.first
    }

    private func resolveWindowAndPane(_ value: String) -> Resolution? {
        let windowPart: String
        let panePart: String?
        if value.hasPrefix("%") {
            return paneByID(String(value.dropFirst()))
        }
        if let dot = value.lastIndex(of: ".") {
            windowPart = String(value[..<dot])
            panePart = String(value[value.index(after: dot)...])
        } else {
            windowPart = value
            panePart = nil
        }

        let window: TmuxTopology.Window?
        if windowPart.isEmpty {
            window = sessionCurrentWindow()
        } else {
            window = windowMatching(windowPart)
        }
        guard let window else {
            return nil
        }
        guard let panePart, !panePart.isEmpty else {
            return Resolution(window: window, pane: nil)
        }
        if panePart.hasPrefix("%") {
            guard let resolution = paneByID(String(panePart.dropFirst())),
                  resolution.window.number == window.number else {
                return nil
            }
            return resolution
        }
        guard let index = Int(panePart), let pane = window.panes.first(where: { $0.index == index }) else {
            return nil
        }
        return Resolution(window: window, pane: pane)
    }

    private func paneByID(_ value: String) -> Resolution? {
        if let number = Int(value) {
            return topology.allPanes.first(where: { $0.pane.number == number })
                .map { Resolution(window: $0.window, pane: $0.pane) }
        }
        return paneByRawID(value)
    }

    private func paneByRawID(_ value: String) -> Resolution? {
        topology.allPanes.first(where: { $0.pane.id == value })
            .map { Resolution(window: $0.window, pane: $0.pane) }
    }

    private func windowByID(_ value: String) -> TmuxTopology.Window? {
        if let number = Int(value) {
            return topology.session.windows.first(where: { $0.number == number })
        }
        return topology.session.windows.first(where: { $0.id == value })
    }

    private func windowMatching(_ value: String, allowsPrefix: Bool = true) -> TmuxTopology.Window? {
        let windows = topology.session.windows
        if value.hasPrefix("@") {
            return windowByID(String(value.dropFirst()))
        }
        if value.hasPrefix("=") {
            let name = String(value.dropFirst())
            return windows.first(where: { $0.name == name })
        }
        if let index = Int(value) {
            return windows.first(where: { $0.index == index })
        }
        if let exact = windows.first(where: { $0.name == value }) ?? windows.first(where: { $0.id == value }) {
            return exact
        }
        return allowsPrefix ? windows.first(where: { $0.name.hasPrefix(value) }) : nil
    }

    private func sessionMatches(_ value: String, allowsPrefix: Bool = true) -> Bool {
        let session = topology.session
        if value.hasPrefix("$") {
            return Int(value.dropFirst()) == session.number
        }
        if value.hasPrefix("=") {
            return String(value.dropFirst()) == session.name
        }
        return value == session.name || (allowsPrefix && session.name.hasPrefix(value))
    }
}
