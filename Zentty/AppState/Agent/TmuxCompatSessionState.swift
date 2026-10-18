import Foundation

/// In-memory tmux identity and option state for the tmux compatibility
/// layer, alive for one app run.
///
/// tmux tools expect numeric object ids (`%3` panes, `@2` windows, `$1`
/// sessions) and validate them with patterns like `/^%\d+$/`. Zentty's own
/// ids are opaque strings, so each pane, worklane and Zentty window gets a
/// stable number the first time the shim sees it. `TMUX_PANE` is generated
/// from the same table when a pane's environment is built.
///
/// Thread-safe: the pane-environment builder runs on the main actor while
/// the IPC handler resolves targets on the socket queue.
final class TmuxCompatSessionState: @unchecked Sendable {
    static let shared = TmuxCompatSessionState()

    enum OptionScope: Hashable {
        case global
        case session(String)
        case window(String)
        case pane(String)
    }

    private let lock = NSLock()
    private var paneNumbers = NumberTable()
    private var windowNumbers = NumberTable()
    private var sessionNumbers = NumberTable()
    private var sessionCreated: [String: Int] = [:]
    private var options: [OptionScope: [String: String]] = [:]
    private var pinnedPanePIDs: [String: Int32] = [:]
    private var startCommands: [String: String] = [:]
    private var shimCreatedPanes: Set<String> = []
    private var shimPaneCreationDates: [String: Date] = [:]
    private var paneGroups: [String: String] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - numeric ids

    func paneNumber(for paneID: String) -> Int {
        locked { paneNumbers.number(for: paneID) }
    }

    func windowNumber(for worklaneID: String) -> Int {
        locked { windowNumbers.number(for: worklaneID) }
    }

    func sessionNumber(for windowID: String) -> Int {
        locked {
            let number = sessionNumbers.number(for: windowID)
            if sessionCreated[windowID] == nil {
                sessionCreated[windowID] = Int(now().timeIntervalSince1970)
            }
            return number
        }
    }

    func sessionCreatedTimestamp(for windowID: String) -> Int {
        _ = sessionNumber(for: windowID)
        return locked { sessionCreated[windowID] ?? 0 }
    }

    func paneID(forNumber number: Int) -> String? {
        locked { paneNumbers.key(for: number) }
    }

    func worklaneID(forNumber number: Int) -> String? {
        locked { windowNumbers.key(for: number) }
    }

    func windowID(forSessionNumber number: Int) -> String? {
        locked { sessionNumbers.key(for: number) }
    }

    /// Moves `%N` from `oldPaneID` to `newPaneID`, so a pane replaced by
    /// `respawn-pane` keeps the id the tool already holds.
    func rebindPane(from oldPaneID: String, to newPaneID: String) {
        locked {
            paneNumbers.rebind(from: oldPaneID, to: newPaneID)
            if let paneOptions = options.removeValue(forKey: .pane(oldPaneID)) {
                options[.pane(newPaneID)] = paneOptions
            }
            pinnedPanePIDs.removeValue(forKey: oldPaneID)
            if shimCreatedPanes.remove(oldPaneID) != nil {
                shimCreatedPanes.insert(newPaneID)
            }
            if let group = paneGroups.removeValue(forKey: oldPaneID) {
                paneGroups[newPaneID] = group
            }
        }
    }

    // MARK: - pane groups

    /// The panes one `new-window` or `new-session -P` call made, plus panes
    /// later split from them. tmux tools see each group as a window of its
    /// own (`@N`), so a group's `kill-window` or window target never reaches
    /// another team's panes or the user's.
    static func paneGroupKey(creatorPaneID: String) -> String {
        "tmux-window:\(creatorPaneID)"
    }

    func assignPaneGroup(_ paneID: String, group: String) {
        locked { paneGroups[paneID] = group }
    }

    func paneGroup(for paneID: String) -> String? {
        locked { paneGroups[paneID] }
    }

    // MARK: - options

    func setOption(_ name: String, value: String, scope: OptionScope) {
        locked { options[scope, default: [:]][name] = value }
    }

    func appendOption(_ name: String, value: String, scope: OptionScope) {
        locked { options[scope, default: [:]][name, default: ""] += value }
    }

    func unsetOption(_ name: String, scope: OptionScope) {
        locked { _ = options[scope]?.removeValue(forKey: name) }
    }

    func option(_ name: String, scope: OptionScope) -> String? {
        locked { options[scope]?[name] }
    }

    func options(in scope: OptionScope) -> [String: String] {
        locked { options[scope] ?? [:] }
    }

    /// Resolves an option the way tmux inherits it: pane, then window, then
    /// session, then global.
    func inheritedOption(
        _ name: String,
        paneID: String?,
        worklaneID: String?,
        windowID: String?
    ) -> String? {
        locked {
            let scopes: [OptionScope?] = [
                paneID.map(OptionScope.pane),
                worklaneID.map(OptionScope.window),
                windowID.map(OptionScope.session),
                .global,
            ]
            for scope in scopes.compactMap({ $0 }) {
                if let value = options[scope]?[name] {
                    return value
                }
            }
            return nil
        }
    }

    // MARK: - pane facts

    /// tmux's `pane_pid` never changes for a pane. The first pid observed is
    /// kept so a later report cannot make a tool think the pane was replaced.
    func pinnedPanePID(for paneID: String, observed: Int32?) -> Int32? {
        locked {
            if let pinned = pinnedPanePIDs[paneID] {
                return pinned
            }
            guard let observed, observed > 0 else {
                return nil
            }
            pinnedPanePIDs[paneID] = observed
            return observed
        }
    }

    func recordShimPane(_ paneID: String, startCommand: String?) {
        locked {
            shimCreatedPanes.insert(paneID)
            shimPaneCreationDates[paneID] = now()
            if let startCommand, !startCommand.isEmpty {
                startCommands[paneID] = startCommand
            }
        }
    }

    /// Records the command a pane started with, without marking the pane as
    /// one the shim created.
    func recordStartCommand(_ paneID: String, startCommand: String?) {
        locked {
            if let startCommand, !startCommand.isEmpty {
                startCommands[paneID] = startCommand
            }
        }
    }

    func isShimCreatedPane(_ paneID: String) -> Bool {
        locked { shimCreatedPanes.contains(paneID) }
    }

    /// True for a pane the shim created within the last `interval` seconds:
    /// its shell may still be starting and about to report its pid.
    func isRecentShimPane(_ paneID: String, within interval: TimeInterval) -> Bool {
        locked {
            guard let created = shimPaneCreationDates[paneID] else {
                return false
            }
            return now().timeIntervalSince(created) < interval
        }
    }

    func startCommand(for paneID: String) -> String? {
        locked { startCommands[paneID] }
    }

    func forgetPane(_ paneID: String) {
        locked {
            shimCreatedPanes.remove(paneID)
            shimPaneCreationDates.removeValue(forKey: paneID)
            startCommands.removeValue(forKey: paneID)
            pinnedPanePIDs.removeValue(forKey: paneID)
            options.removeValue(forKey: .pane(paneID))
            paneGroups.removeValue(forKey: paneID)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Bidirectional key <-> number table. Numbers start at 0 like tmux and are
/// never reused within a run.
private struct NumberTable {
    private var numbersByKey: [String: Int] = [:]
    private var keysByNumber: [Int: String] = [:]
    private var next = 0

    mutating func number(for key: String) -> Int {
        if let existing = numbersByKey[key] {
            return existing
        }
        let number = next
        next += 1
        numbersByKey[key] = number
        keysByNumber[number] = key
        return number
    }

    func key(for number: Int) -> String? {
        keysByNumber[number]
    }

    mutating func rebind(from oldKey: String, to newKey: String) {
        guard let number = numbersByKey.removeValue(forKey: oldKey) else {
            return
        }
        if let stale = numbersByKey.removeValue(forKey: newKey) {
            keysByNumber.removeValue(forKey: stale)
        }
        numbersByKey[newKey] = number
        keysByNumber[number] = newKey
    }
}
