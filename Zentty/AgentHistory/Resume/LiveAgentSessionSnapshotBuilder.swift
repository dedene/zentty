import Foundation

/// Finds the agent sessions running in Zentty panes right now, across every window.
///
/// A pane offers up to three candidates, strongest first: its visible agent status, the
/// per-root-session metadata, and the reducer's root sessions. A candidate counts only when its
/// tool has history, its id is a real session id, and its process is alive. Remote panes and
/// panes still waiting to auto-resume a restored session never count.
@MainActor
enum LiveAgentSessionSnapshotBuilder {
    static func snapshot(
        from sources: [MenuBarWorklaneSource],
        preferredWindowID: WindowID?,
        isProcessAlive: (Int32) -> Bool = SessionRestoreDraftExporter.defaultIsProcessAlive
    ) -> LiveAgentSessionSnapshot {
        let primaryTextByPane = primaryTexts(from: sources)
        var locationsByKey: [AgentHistorySessionKey: [LiveAgentSessionLocation]] = [:]

        for source in sources {
            let store = source.worklaneStore
            for (index, worklane) in store.worklanes.enumerated() {
                let worklaneDisplayName = worklane.title ?? "Worklane \(index + 1)"
                for pane in worklane.paneStripState.panes {
                    guard let auxiliary = worklane.auxiliaryStateByPaneID[pane.id] else {
                        continue
                    }
                    let context = PaneContext(
                        source: source,
                        worklaneID: worklane.id,
                        worklaneDisplayName: worklaneDisplayName,
                        pane: pane,
                        auxiliary: auxiliary,
                        paneDisplayName: primaryTextByPane[PaneReference(windowID: source.windowID, paneID: pane.id)]
                            ?? pane.title
                    )
                    for location in locations(in: context, isProcessAlive: isProcessAlive) {
                        locationsByKey[location.key, default: []].append(location)
                    }
                }
            }
        }

        return LiveAgentSessionSnapshot(
            locationsByKey: locationsByKey.mapValues { locations in
                locations.sorted { isOrderedBefore($0, $1, preferredWindowID: preferredWindowID) }
            }
        )
    }

    // MARK: - Candidates

    private struct PaneReference: Hashable {
        let windowID: WindowID
        let paneID: PaneID
    }

    private struct PaneContext {
        let source: MenuBarWorklaneSource
        let worklaneID: WorklaneID
        let worklaneDisplayName: String
        let pane: PaneState
        let auxiliary: PaneAuxiliaryState
        let paneDisplayName: String
    }

    private struct Candidate {
        let tool: AgentTool
        let rawSessionID: String
        let pid: Int32?
        let updatedAt: Date
        let matchSource: LiveAgentSessionLocation.MatchSource
    }

    private static func locations(
        in context: PaneContext,
        isProcessAlive: (Int32) -> Bool
    ) -> [LiveAgentSessionLocation] {
        let auxiliary = context.auxiliary
        guard auxiliary.shellContext?.scope != .remote,
              !auxiliary.raw.restoredAgentAutoResumePending else {
            return []
        }

        let workingDirectory = SessionRestoreDraftExporter.workingDirectory(
            agentStatus: auxiliary.agentStatus,
            auxiliary: auxiliary,
            pane: context.pane,
            restoredDraft: nil
        )
        var bestByKey: [AgentHistorySessionKey: LiveAgentSessionLocation] = [:]

        for candidate in candidates(in: auxiliary) {
            guard let agent = AgentHistoryAgent(tool: candidate.tool),
                  !SessionRestoreDraftExporter.isPlaceholderSessionID(candidate.rawSessionID, for: candidate.tool),
                  let nativeID = agent.normalizedSessionID(candidate.rawSessionID),
                  let pid = livePID(for: candidate, auxiliary: auxiliary, isProcessAlive: isProcessAlive) else {
                continue
            }

            let location = LiveAgentSessionLocation(
                key: AgentHistorySessionKey(agent: agent, nativeID: nativeID),
                windowID: context.source.windowID,
                worklaneID: context.worklaneID,
                paneID: context.pane.id,
                tool: candidate.tool,
                rawSessionID: candidate.rawSessionID,
                pid: pid,
                paneDisplayName: context.paneDisplayName,
                worklaneDisplayName: context.worklaneDisplayName,
                windowTitle: context.source.windowTitle,
                workingDirectory: workingDirectory,
                updatedAt: candidate.updatedAt,
                matchSource: candidate.matchSource
            )
            if let existing = bestByKey[location.key], !isStrongerWithinPane(location, than: existing) {
                continue
            }
            bestByKey[location.key] = location
        }

        return Array(bestByKey.values)
    }

    private static func candidates(in auxiliary: PaneAuxiliaryState) -> [Candidate] {
        var candidates: [Candidate] = []

        if let status = auxiliary.agentStatus,
           status.parentSessionID == nil,
           let sessionID = trimmed(status.sessionID) {
            candidates.append(Candidate(
                tool: status.tool,
                rawSessionID: sessionID,
                pid: status.trackedPID,
                updatedAt: status.updatedAt,
                matchSource: .status
            ))
        }

        if let metadata = auxiliary.raw.agentMetadata,
           let sessionID = trimmed(metadata.sessionID) {
            candidates.append(Candidate(
                tool: metadata.tool,
                rawSessionID: sessionID,
                pid: metadata.pid,
                updatedAt: auxiliary.presentation.updatedAt,
                matchSource: .metadata
            ))
        }

        for session in auxiliary.agentReducerState.sessionsByID.values where session.parentSessionID == nil {
            guard let sessionID = trimmed(session.sessionID) else { continue }
            candidates.append(Candidate(
                tool: session.tool,
                rawSessionID: sessionID,
                pid: session.trackedPID,
                updatedAt: session.updatedAt,
                matchSource: .reducer
            ))
        }

        return candidates
    }

    /// The process that proves the session is running, or nil when it is not.
    /// A candidate without a pid falls back to the pane's foreground agent, except reducer
    /// sessions: they can outlive their process and would claim whichever agent runs now.
    private static func livePID(
        for candidate: Candidate,
        auxiliary: PaneAuxiliaryState,
        isProcessAlive: (Int32) -> Bool
    ) -> Int32? {
        if let pid = candidate.pid {
            return isProcessAlive(pid) ? pid : nil
        }
        guard candidate.matchSource != .reducer,
              let foreground = auxiliary.raw.foregroundAgentSnapshot?.agent,
              foreground.tool == candidate.tool else {
            return nil
        }
        return foreground.pid
    }

    // MARK: - Ordering and names

    private static func isStrongerWithinPane(
        _ lhs: LiveAgentSessionLocation,
        than rhs: LiveAgentSessionLocation
    ) -> Bool {
        if lhs.matchSource != rhs.matchSource {
            return lhs.matchSource < rhs.matchSource
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    /// Presenting window first, then the strongest evidence, then the most recent update.
    private static func isOrderedBefore(
        _ lhs: LiveAgentSessionLocation,
        _ rhs: LiveAgentSessionLocation,
        preferredWindowID: WindowID?
    ) -> Bool {
        let lhsPreferred = preferredWindowID != nil && lhs.windowID == preferredWindowID
        let rhsPreferred = preferredWindowID != nil && rhs.windowID == preferredWindowID
        if lhsPreferred != rhsPreferred {
            return lhsPreferred
        }
        if lhs.matchSource != rhs.matchSource {
            return lhs.matchSource < rhs.matchSource
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.paneID.rawValue != rhs.paneID.rawValue {
            return lhs.paneID.rawValue < rhs.paneID.rawValue
        }
        return lhs.windowID.rawValue < rhs.windowID.rawValue
    }

    private static func primaryTexts(from sources: [MenuBarWorklaneSource]) -> [PaneReference: String] {
        var result: [PaneReference: String] = [:]
        for snapshot in MenuBarPaneSnapshotBuilder.snapshots(from: sources) {
            let reference = PaneReference(windowID: snapshot.windowID, paneID: snapshot.paneID)
            if result[reference] == nil {
                result[reference] = snapshot.primaryText
            }
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
