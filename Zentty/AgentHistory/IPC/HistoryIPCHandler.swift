import AppKit
import os

/// Glue between the IPC server and `HistoryIPCService`: parse first, then one main-thread hop for
/// the calling pane's folder, the live sessions and the History settings (no I/O, no SQLite),
/// then the query on the calling (IPC) thread.
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
            let caller = try PaneControlIPCHandler.onMain { try callerSnapshot(for: target) }
            let result = try HistoryIPCService().respond(to: command, caller: caller)
            let count = result.search?.results.count ?? result.show?.turns.count
            log(kind: command.ipcSubcommand, scope: scopeName, count: count, started: started, error: nil)
            return AgentIPCResponseResult(history: result)
        } catch {
            log(kind: command.ipcSubcommand, scope: scopeName, count: nil, started: started, error: error)
            throw error
        }
    }

    @MainActor
    private static func callerSnapshot(for target: AgentIPCTarget) throws -> HistoryIPCCaller {
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
        return HistoryIPCCaller(
            paneCWD: presentation.cwd,
            paneRepoRoot: presentation.repoRoot,
            isRemotePane: presentation.isRemotePane,
            allowAgentsAllProjects: controller.allowsAgentsAllProjects,
            liveKeys: liveKeys,
            exclusions: controller.exclusions,
            dataSource: AgentHistoryIPCDataSource(controller: controller)
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
