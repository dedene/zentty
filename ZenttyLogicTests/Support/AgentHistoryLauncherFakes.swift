import Foundation
import XCTest
@testable import Zentty

// Fakes for `AgentHistoryLauncherTests`: window hosts over real worklane stores, a usage
// recorder, a worktree creator that completes off-main, and an in-memory file tree.

/// The windows a launcher sees. Tests change them while a worktree recreation is in flight.
@MainActor
final class LauncherWindows {
    var hosts: [LauncherFakeHost]
    var presenting: LauncherFakeHost?

    init(hosts: [LauncherFakeHost], presenting: LauncherFakeHost?) {
        self.hosts = hosts
        self.presenting = presenting
    }
}

struct LauncherNavigation: Equatable {
    let worklaneID: WorklaneID
    let paneID: PaneID
}

struct LauncherForkRequest: Equatable {
    let paneID: PaneID
    let destination: AgentForkDestination?
    let sessionOverride: AgentForkSessionOverride?
}

struct LauncherRecordedOpen: Equatable {
    let rowID: Int64
    let at: Date
}

/// A window host over a real worklane store; mirrors `MainWindowController`'s forwarding.
@MainActor
final class LauncherFakeHost: AgentHistoryWindowHost {
    let windowID: WindowID
    let worklaneStore: WorklaneStore
    var menuBarDisplayTitle: String { "Window \(windowID.rawValue)" }
    var forkError: Error?
    var splitUnavailable = false
    var onToast: ((String) -> Void)?
    private(set) var toasts: [String] = []
    private(set) var navigations: [LauncherNavigation] = []
    private(set) var forkRequests: [LauncherForkRequest] = []

    init(windowID: WindowID, store: WorklaneStore) {
        self.windowID = windowID
        worklaneStore = store
    }

    func navigateToPane(worklaneID: WorklaneID, paneID: PaneID) {
        navigations.append(LauncherNavigation(worklaneID: worklaneID, paneID: paneID))
    }

    func forkAgentConversation(
        paneID: PaneID,
        destination: AgentForkDestination?,
        sessionOverride: AgentForkSessionOverride?
    ) throws -> WorklaneStore.AgentForkResult {
        forkRequests.append(LauncherForkRequest(paneID: paneID, destination: destination, sessionOverride: sessionOverride))
        if let forkError {
            throw forkError
        }
        return try worklaneStore.forkAgentConversation(
            paneID: paneID,
            destination: destination ?? .splitRight,
            sessionOverride: sessionOverride
        )
    }

    func launchInNewWorklane(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane {
        worklaneStore.openWorklane(request, anchorWorklaneID: worklaneStore.activeWorklane?.id)
    }

    func launchInSplitRight(_ request: PaneLaunchRequest) -> WorklaneStore.LaunchedPane? {
        guard !splitUnavailable, let worklane = worklaneStore.activeWorklane else {
            return nil
        }
        return worklaneStore.openSplit(
            in: worklane.id,
            targetPaneID: worklane.paneStripState.focusedPaneID,
            isHorizontal: true,
            request
        )
    }

    func showToast(message: String) {
        toasts.append(message)
        onToast?(message)
    }
}

final class LauncherFakeUsageRecorder: AgentHistoryUsageRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LauncherRecordedOpen] = []

    var opens: [LauncherRecordedOpen] {
        lock.withLock { recorded }
    }

    func recordOpen(sessionRowID: Int64, at date: Date) {
        lock.withLock { recorded.append(LauncherRecordedOpen(rowID: sessionRowID, at: date)) }
    }
}

/// Completes on a background queue, like `GitWorktreeCreator`.
final class LauncherFakeWorktreeCreator: AgentHistoryWorktreeCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [AgentHistoryWorktreeRecreation] = []
    private let result: Result<Void, AgentHistoryWorktreeError>
    private let onRecreate: @Sendable (AgentHistoryWorktreeRecreation) -> Void
    private let handledLock = NSLock()
    private var handledExpectation: XCTestExpectation?

    init(
        result: Result<Void, AgentHistoryWorktreeError>,
        onRecreate: @escaping @Sendable (AgentHistoryWorktreeRecreation) -> Void = { _ in }
    ) {
        self.result = result
        self.onRecreate = onRecreate
    }

    /// Fulfilled on main once the launcher has handled the completion: the launcher hops to
    /// main first, so a main-queue block queued after the completion runs after its handling.
    func expectHandled(_ expectation: XCTestExpectation) {
        handledLock.withLock { handledExpectation = expectation }
    }

    var requests: [AgentHistoryWorktreeRecreation] {
        lock.withLock { received }
    }

    func recreate(
        _ recreation: AgentHistoryWorktreeRecreation,
        completion: @escaping @Sendable (Result<Void, AgentHistoryWorktreeError>) -> Void
    ) {
        lock.withLock { received.append(recreation) }
        let result = result
        let onRecreate = onRecreate
        DispatchQueue.global(qos: .userInitiated).async {
            if case .success = result {
                onRecreate(recreation)
            }
            completion(result)
            if let handled = self.handledLock.withLock({ self.handledExpectation }) {
                DispatchQueue.main.async { handled.fulfill() }
            }
        }
    }
}

/// An in-memory tree the fake worktree creator can add folders to.
final class LauncherMutableFileSystem: AgentHistoryFileSystemProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var tree: FakeHistoryFileSystem

    init(base: FakeHistoryFileSystem) {
        tree = base
    }

    func makeDirectory(_ path: String) {
        lock.withLock { tree.makeDirectory(path) }
    }

    func isDirectory(_ path: String) -> Bool {
        lock.withLock { tree.isDirectory(path) }
    }

    func fileExists(_ path: String) -> Bool {
        lock.withLock { tree.fileExists(path) }
    }

    func contents(_ path: String) -> String? {
        lock.withLock { tree.contents(path) }
    }

    func directoryEntries(_ path: String) -> [String] {
        lock.withLock { tree.directoryEntries(path) }
    }
}

struct LauncherTestGitResolver: PaneGitContextResolving {
    func resolve(for workingDirectory: String) async -> PaneGitContext {
        PaneGitContext(workingDirectory: workingDirectory, repositoryRoot: nil, reference: nil)
    }
}
