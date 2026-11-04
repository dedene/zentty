import CoreGraphics
import Foundation

/// A command to run in a fresh pane: where, what, and with which extra
/// environment. Used by fork and Agent History resume.
struct PaneLaunchRequest: Equatable, Sendable {
    var workingDirectory: String
    var command: String?
    var environment: [String: String] = [:]
    /// Worklane title for `openWorklane`; pane custom title for `openSplit`.
    var title: String? = nil
}

extension WorklaneStore {
    struct LaunchedPane: Equatable, Sendable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    /// Keys a launch request may never set. Any `ZENTTY_`-prefixed key is
    /// rejected as well: those identify the pane to Zentty's own tooling.
    static let reservedLaunchEnvironmentKeys: Set<String> = ["PATH", "TMUX", "TMUX_PANE"]

    /// Opens `command` in a new worklane holding a single pane, inserts it
    /// per the new-worklane placement setting (after `anchorWorklaneID` when
    /// placement is "after current") and selects it.
    ///
    /// The command is one-shot: restoring the pane later never replays it.
    @discardableResult
    func openWorklane(
        workingDirectory: String,
        command: String?,
        environment: [String: String] = [:],
        title: String? = nil,
        anchorWorklaneID: WorklaneID? = nil,
        sourceShellContext: PaneShellContext? = nil
    ) -> LaunchedPane {
        var worklane = WorklaneState(
            id: runtimeIdentity.makeWorklaneID(),
            title: title,
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        var pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: 0,
            workingDirectory: workingDirectory,
            sourceShellContext: sourceShellContext,
            command: command
        )
        pane.sessionRequest.surfaceContext = .tab
        pane.sessionRequest.replaysCommandOnRestore = false
        let sanitized = Self.sanitizedLaunchEnvironment(environment)
        if !sanitized.isEmpty {
            pane.sessionRequest.environmentVariables.merge(sanitized) { _, new in new }
            WorklaneSessionEnvironment.applyTmuxPaneIdentity(
                to: &pane.sessionRequest.environmentVariables,
                paneID: pane.id
            )
        }
        worklane.paneStripState.insertPaneAsColumn(
            pane,
            atColumnIndex: 0,
            width: layoutContext.singlePaneWidth
        )

        worklanes.insert(worklane, at: insertionIndexForNewWorklane(anchorWorklaneID: anchorWorklaneID))
        notify(.worklaneListChanged)
        selectWorklane(id: worklane.id)
        return LaunchedPane(worklaneID: worklane.id, paneID: pane.id)
    }

    @discardableResult
    func openWorklane(_ request: PaneLaunchRequest, anchorWorklaneID: WorklaneID? = nil) -> LaunchedPane {
        openWorklane(
            workingDirectory: request.workingDirectory,
            command: request.command,
            environment: request.environment,
            title: request.title,
            anchorWorklaneID: anchorWorklaneID
        )
    }

    /// Opens `request` in a new pane split from `targetPaneID` (or the
    /// worklane's focused pane when nil). Returns nil when the worklane or
    /// target pane does not exist. The command is one-shot, as above.
    @discardableResult
    func openSplit(
        in worklaneID: WorklaneID,
        targetPaneID: PaneID?,
        isHorizontal: Bool = true,
        _ request: PaneLaunchRequest
    ) -> LaunchedPane? {
        var sessionRequest = TerminalSessionRequest(
            workingDirectory: request.workingDirectory,
            command: request.command,
            environmentVariables: Self.sanitizedLaunchEnvironment(request.environment)
        )
        sessionRequest.replaysCommandOnRestore = false

        guard let paneID = splitWithLayout(
            in: worklaneID,
            placement: .afterFocused,
            isHorizontal: isHorizontal,
            layout: .none,
            availableWidth: layoutContext.availableWidth,
            leadingVisibleInset: layoutContext.leadingVisibleInset,
            availableSize: .zero,
            minimumSizeByPaneID: [:],
            targetPaneID: targetPaneID,
            sessionRequest: sessionRequest
        ) else {
            return nil
        }
        if let title = request.title {
            setPaneCustomTitle(title, on: paneID)
        }
        return LaunchedPane(worklaneID: worklaneID, paneID: paneID)
    }

    /// Drops entries whose name is not a portable shell identifier
    /// (`^[A-Za-z_][A-Za-z0-9_]*$`), is reserved, or starts with `ZENTTY_`.
    static func sanitizedLaunchEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            isPortableEnvironmentName(key)
                && !reservedLaunchEnvironmentKeys.contains(key)
                && !key.hasPrefix("ZENTTY_")
        }
    }

    private static func isPortableEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first else {
            return false
        }
        func isLetterOrUnderscore(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
        }
        guard isLetterOrUnderscore(first) else {
            return false
        }
        return name.utf8.allSatisfy { isLetterOrUnderscore($0) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
