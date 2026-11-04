import AppKit
import os

/// Glue between the IPC server and `HistoryIPCService`: parse first, then one main-thread hop for
/// the calling pane's folder, the live sessions and the agent access setting (no disk reads, no
/// SQLite), then on the calling (IPC) thread the exclusions matcher (it may resolve symlinks)
/// and the query.
enum HistoryIPCHandler {
    static func handle(request: AgentIPCRequest, target: AgentIPCTarget) throws -> AgentIPCResponseResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let command: HistoryIPCCommand
        do {
            command = try HistoryIPCCommand.parse(subcommand: request.subcommand, arguments: request.arguments)
        } catch {
            log(kind: request.subcommand, scope: nil, count: nil, started: started, error: error)
            throw error
        }

        let scopeName = command.allProjects ? "all" : "project"
        do {
            let caller = try makeCaller { try PaneControlIPCHandler.onMain { try paneSnapshot(for: target) } }
            let result = try HistoryIPCService().respond(to: command, caller: caller)
            let count = result.search?.results.count ?? result.show?.turns.count
            log(kind: command.ipcSubcommand, scope: scopeName, count: count, started: started, error: nil)
            return AgentIPCResponseResult(history: result)
        } catch {
            log(kind: command.ipcSubcommand, scope: scopeName, count: nil, started: started, error: error)
            throw error
        }
    }

    /// The main hop (`pane`) first; the matcher only after it returns, so a cold cache costs the
    /// IPC thread, not the main thread.
    static func makeCaller(pane: () throws -> HistoryIPCPaneSnapshot) throws -> HistoryIPCCaller {
        let snapshot = try pane()
        return HistoryIPCCaller(
            paneCWD: snapshot.paneCWD,
            paneRepoRoot: snapshot.paneRepoRoot,
            isRemotePane: snapshot.isRemotePane,
            allowAgentsAllProjects: snapshot.allowAgentsAllProjects,
            liveKeys: snapshot.liveKeys,
            exclusions: snapshot.exclusions(),
            dataSource: snapshot.dataSource
        )
    }

    @MainActor
    private static func paneSnapshot(for target: AgentIPCTarget) throws -> HistoryIPCPaneSnapshot {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let resolved = PaneIPCHandler.resolveTarget(target, appDelegate: appDelegate)
        else {
            throw PaneRoutingError.paneNotFound
        }
        let worklane = resolved.windowController.discoveryWorkspaceState.worklanes
            .first { $0.id == resolved.target.worklaneID }
        guard let auxiliary = worklane?.auxiliaryStateByPaneID[resolved.target.paneID] else {
            throw PaneRoutingError.paneNotFound
        }
        let presentation = auxiliary.presentation
        let controller = AgentHistoryController.shared
        let liveKeys = LiveAgentSessionSnapshotBuilder.snapshot(
            from: appDelegate.agentHistoryWorklaneSources(),
            preferredWindowID: nil
        ).liveKeys
        return HistoryIPCPaneSnapshot(
            paneCWD: presentation.cwd,
            paneRepoRoot: presentation.repoRoot,
            isRemotePane: presentation.isRemotePane,
            allowAgentsAllProjects: controller.allowsAgentsAllProjects,
            liveKeys: liveKeys,
            dataSource: AgentHistoryIPCDataSource(controller: controller),
            exclusions: { controller.exclusions }
        )
    }

    /// Kind, scope kind, count, duration and error code only: never the query, ids or paths.
    private static func log(kind: String?, scope: String?, count: Int?, started: UInt64, error: Error?) {
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let kindName = kind.flatMap { [HistoryIPC.searchSubcommand, HistoryIPC.showSubcommand].contains($0) ? $0 : nil }
            ?? "unknown"
        if let error {
            let code = (error as? HistoryIPCError)?.ipcCode ?? "other"
            AgentHistoryLog.search.info(
                "IPC \(kindName, privacy: .public) scope=\(scope ?? "-", privacy: .public) failed code=\(code, privacy: .public) ms=\(elapsedMs, privacy: .public)"
            )
        } else {
            AgentHistoryLog.search.info(
                "IPC \(kindName, privacy: .public) scope=\(scope ?? "-", privacy: .public) count=\(count ?? 0, privacy: .public) ms=\(elapsedMs, privacy: .public)"
            )
        }
    }
}

/// What the main-thread hop captures for one `zentty history` call: memory only.
struct HistoryIPCPaneSnapshot: Sendable {
    var paneCWD: String?
    var paneRepoRoot: String?
    var isRemotePane: Bool
    var allowAgentsAllProjects: Bool
    var liveKeys: Set<AgentHistorySessionKey>
    var dataSource: (any HistoryIPCDataSource)?
    /// Called after the hop, off main: a cold matcher cache canonicalizes folders (disk).
    var exclusions: @Sendable () -> AgentHistoryExclusionMatcher
}
