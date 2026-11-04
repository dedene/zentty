import Foundation

extension MainWindowController: AgentHistoryWindowHost {
    /// The windows Agent History can jump to, fork in or resume in; this window alone when the
    /// app delegate has not wired the provider.
    var agentHistoryHosts: [any AgentHistoryWindowHost] {
        agentHistoryHostsProvider?() ?? [self]
    }

    /// The worklane stores the live-session index watches.
    var agentHistorySources: [MenuBarWorklaneSource] {
        agentHistorySourcesProvider?() ?? [
            MenuBarWorklaneSource(windowID: windowID, windowTitle: menuBarDisplayTitle, worklaneStore: worklaneStore),
        ]
    }
}
