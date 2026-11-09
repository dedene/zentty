import AppKit
import CoreGraphics
import Foundation
import os

/// One on-screen window, as much as we need to spot a 1Password prompt.
struct OnePasswordPromptWindow: Hashable, Sendable {
    let id: Int
    let ownerName: String
}

/// Where the user was before a 1Password prompt pulled them to another pane.
struct OnePasswordPromptFocusLocation: Equatable, Sendable {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID

    func matches(_ source: OnePasswordPromptPaneSource) -> Bool {
        windowID == source.windowID && worklaneID == source.worklaneID && paneID == source.paneID
    }
}

protocol OnePasswordPromptWindowSnapshotting: Sendable {
    func onScreenWindows() -> [OnePasswordPromptWindow]
}

/// Reads the on-screen window list. Owner names come back without any
/// screen-recording entitlement; window titles would not, so we never rely on them.
struct DarwinOnePasswordPromptWindowSnapshotter: OnePasswordPromptWindowSnapshotting {
    func onScreenWindows() -> [OnePasswordPromptWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let owner = info[kCGWindowOwnerName as String] as? String else {
                return nil
            }
            return OnePasswordPromptWindow(id: id, ownerName: owner)
        }
    }
}

/// Jumps to the pane that made 1Password prompt for approval.
///
/// 1Password's approval prompt is a floating panel that never activates the
/// app, so there is no activation notification to hook. Instead this polls the
/// on-screen window list a few times a second and, when a new window from
/// 1Password (or from the system Touch ID sheet host) appears, scans every
/// pane's process tree for a live `op` or SSH-agent request. The matching pane
/// is revealed inside Zentty without activating Zentty, so the prompt keeps
/// focus and the right pane is already selected when the user returns.
///
/// Every trigger is gated by attribution: a new window only causes a jump when
/// some pane really holds a live 1Password request, so the generic Touch ID
/// host is a safe trigger too.
///
/// Once the prompt is answered (approved or dismissed both close its window)
/// the coordinator can jump back to where the user was. The return waits for
/// every prompt window it saw to leave the screen plus a short grace period,
/// because the Touch ID sheet closes about a second before 1Password's own
/// approval panel opens. For `op` requests it additionally waits for the
/// client process to exit, and gives up when the process keeps running, since
/// then the pane is doing real work (`op run`) rather than waiting on a prompt.
/// The return is skipped when the user has meanwhile moved to another pane.
@MainActor
final class OnePasswordPromptFocusCoordinator {
    struct Hooks {
        let isEnabled: () -> Bool
        /// Whether to jump back to the previous pane once the prompt closes.
        var isReturnEnabled: () -> Bool = { false }
        let sources: () -> [OnePasswordPromptPaneSource]
        /// Whether the pane is already the focused pane of its own window.
        let isPaneFocused: (OnePasswordPromptPaneSource) -> Bool
        let reveal: (OnePasswordPromptCandidate) -> Void
        /// The pane the user is currently in, across all windows.
        var currentFocus: () -> OnePasswordPromptFocusLocation? = { nil }
        var restoreFocus: (OnePasswordPromptFocusLocation) -> Void = { _ in }
    }

    private struct PendingReturn {
        let origin: OnePasswordPromptFocusLocation
        var candidate: OnePasswordPromptCandidate?
        /// Prompt windows seen since the trigger; the return waits for all of them to go.
        var promptWindowIDs: Set<Int>
        /// When the last prompt window left the screen.
        var clearedAt: Date?
    }

    /// Window owners whose new windows can be an approval prompt.
    static let promptWindowOwners: Set<String> = ["1Password", "UserNotificationCenter"]
    static let onePasswordBundleIdentifier = "com.1password.1password"
    /// Ticks between checks whether 1Password is running at all.
    private static let presenceCheckTicks = 20
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "OnePasswordPromptFocus")

    private let hooks: Hooks
    private let attributor: OnePasswordPromptAttributor
    private let snapshotter: any OnePasswordPromptWindowSnapshotting
    private let pollInterval: TimeInterval
    private let minimumInterval: TimeInterval
    private let scanExecutor: (@escaping @Sendable () -> Void) -> Void
    private let now: () -> Date
    private let isOnePasswordRunning: () -> Bool
    private let isProcessAlive: (Int32) -> Bool
    /// How long every prompt window must stay gone before jumping back.
    private let returnGrace: TimeInterval
    /// How long after the grace an `op` client may keep running before the return is abandoned.
    private let returnProcessTimeout: TimeInterval
    private var pendingReturn: PendingReturn?
    private var timer: Timer?
    private var knownWindowIDs: Set<Int>?
    private var ticksUntilPresenceCheck = 0
    private var onePasswordPresent = false
    private var lastHandledAt: Date?
    private var scanGeneration = 0

    init(
        hooks: Hooks,
        attributor: OnePasswordPromptAttributor = OnePasswordPromptAttributor(
            processProvider: OnePasswordPromptDarwinProcessProvider()
        ),
        snapshotter: any OnePasswordPromptWindowSnapshotting = DarwinOnePasswordPromptWindowSnapshotter(),
        pollInterval: TimeInterval = 0.25,
        minimumInterval: TimeInterval = 0.75,
        returnGrace: TimeInterval = 1.5,
        returnProcessTimeout: TimeInterval = 3,
        isProcessAlive: @escaping (Int32) -> Bool = { pid in
            kill(pid, 0) == 0 || errno != ESRCH
        },
        isOnePasswordRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: OnePasswordPromptFocusCoordinator.onePasswordBundleIdentifier
            ).isEmpty
        },
        scanExecutor: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.hooks = hooks
        self.attributor = attributor
        self.snapshotter = snapshotter
        self.pollInterval = pollInterval
        self.minimumInterval = minimumInterval
        self.returnGrace = returnGrace
        self.returnProcessTimeout = returnProcessTimeout
        self.isProcessAlive = isProcessAlive
        self.isOnePasswordRunning = isOnePasswordRunning
        self.scanExecutor = scanExecutor
        self.now = now
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        timer.tolerance = pollInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        knownWindowIDs = nil
        ticksUntilPresenceCheck = 0
        invalidatePendingWork()
    }

    /// Forgets the tracked jump-back and orphans any attribution scan still running.
    private func invalidatePendingWork() {
        pendingReturn = nil
        scanGeneration += 1
    }

    private func poll() {
        guard hooks.isEnabled() else {
            knownWindowIDs = nil
            invalidatePendingWork()
            return
        }
        if ticksUntilPresenceCheck == 0 {
            onePasswordPresent = isOnePasswordRunning()
            ticksUntilPresenceCheck = Self.presenceCheckTicks
        }
        ticksUntilPresenceCheck -= 1
        guard onePasswordPresent else {
            // Confirmed by the running-apps check, not a window snapshot, so this
            // cannot be the gap between the Touch ID sheet and the approval panel.
            knownWindowIDs = nil
            invalidatePendingWork()
            return
        }
        handleWindowSnapshot(snapshotter.onScreenWindows())
    }

    /// Feeds one window-list sample. Returns true when a scan was started.
    /// The first sample after (re)start only seeds the baseline.
    @discardableResult
    func handleWindowSnapshot(_ windows: [OnePasswordPromptWindow]) -> Bool {
        let currentIDs = Set(windows.map(\.id))
        defer { knownWindowIDs = currentIDs }
        guard let knownWindowIDs else {
            return false
        }

        let newPromptWindows = windows.filter {
            !knownWindowIDs.contains($0.id) && Self.promptWindowOwners.contains($0.ownerName)
        }
        let newPromptWindowIDs = Set(newPromptWindows.map(\.id))
        if pendingReturn != nil {
            pendingReturn?.promptWindowIDs.formUnion(newPromptWindowIDs)
            settlePendingReturn(onScreenIDs: currentIDs)
        }
        guard let trigger = newPromptWindows.first else {
            return false
        }
        return startScan(reason: trigger.ownerName, promptWindowIDs: newPromptWindowIDs)
    }

    /// Advances the jump-back state machine with one window-list sample.
    private func settlePendingReturn(onScreenIDs: Set<Int>) {
        guard var pending = pendingReturn else { return }
        guard hooks.isReturnEnabled() else {
            pendingReturn = nil
            return
        }
        // The scan has not attributed a pane yet; nothing to return from.
        guard let candidate = pending.candidate else { return }

        if !pending.promptWindowIDs.isDisjoint(with: onScreenIDs) {
            pending.clearedAt = nil
            pendingReturn = pending
            return
        }
        let timestamp = now()
        guard let clearedAt = pending.clearedAt else {
            pending.clearedAt = timestamp
            pendingReturn = pending
            return
        }
        let sinceCleared = timestamp.timeIntervalSince(clearedAt)
        guard sinceCleared >= returnGrace else {
            pendingReturn = pending
            return
        }
        if candidate.kind == .cli, isProcessAlive(candidate.pid) {
            if sinceCleared >= returnGrace + returnProcessTimeout {
                Self.logger.info(
                    "op pid=\(candidate.pid, privacy: .public) still running after the prompt closed; not jumping back"
                )
                pendingReturn = nil
            } else {
                pendingReturn = pending
            }
            return
        }
        pendingReturn = nil
        guard hooks.isPaneFocused(candidate.source) else {
            Self.logger.debug("User left the 1Password request pane; not jumping back")
            return
        }
        Self.logger.info("1Password prompt closed; returning to the previous pane")
        hooks.restoreFocus(pending.origin)
    }

    private func startScan(reason: String, promptWindowIDs: Set<Int>) -> Bool {
        let timestamp = now()
        if let lastHandledAt, timestamp.timeIntervalSince(lastHandledAt) < minimumInterval {
            Self.logger.debug("New \(reason, privacy: .public) window within the debounce window; ignoring")
            return false
        }
        lastHandledAt = timestamp

        let sources = hooks.sources()
        let scannable = sources.filter { $0.rootPID != nil }
        guard !scannable.isEmpty else {
            Self.logger.info(
                "New \(reason, privacy: .public) window but no pane reports a root PID (\(sources.count, privacy: .public) panes)"
            )
            return false
        }
        Self.logger.debug(
            "New \(reason, privacy: .public) window; scanning \(scannable.count, privacy: .public) of \(sources.count, privacy: .public) panes"
        )

        scanGeneration += 1
        let generation = scanGeneration
        beginPendingReturn(promptWindowIDs: promptWindowIDs)
        let attributor = self.attributor
        scanExecutor { [weak self] in
            let candidate = attributor.bestCandidate(in: scannable)
            Task { @MainActor in
                self?.finishScan(generation: generation, candidate: candidate)
            }
        }
        return true
    }

    /// Remembers where the user is before a reveal. A follow-up prompt window
    /// for a request we are already tracking (Touch ID sheet, then the
    /// approval panel) keeps the original origin.
    private func beginPendingReturn(promptWindowIDs: Set<Int>) {
        guard hooks.isReturnEnabled() else {
            pendingReturn = nil
            return
        }
        if let pending = pendingReturn, pending.candidate != nil {
            pendingReturn?.promptWindowIDs.formUnion(promptWindowIDs)
            pendingReturn?.clearedAt = nil
            return
        }
        guard let origin = hooks.currentFocus() else {
            pendingReturn = nil
            return
        }
        pendingReturn = PendingReturn(origin: origin, candidate: nil, promptWindowIDs: promptWindowIDs)
    }

    private func finishScan(generation: Int, candidate: OnePasswordPromptCandidate?) {
        guard generation == scanGeneration, hooks.isEnabled() else { return }
        guard let candidate else {
            Self.logger.debug("No pane holds a live 1Password request")
            if pendingReturn?.candidate == nil {
                pendingReturn = nil
            }
            return
        }
        if hooks.isPaneFocused(candidate.source) {
            Self.logger.debug("1Password request pane already focused pid=\(candidate.pid, privacy: .public)")
            if pendingReturn?.candidate == nil {
                pendingReturn = nil
            }
            return
        }
        if var pending = pendingReturn, pending.candidate == nil {
            if pending.origin.matches(candidate.source) {
                pendingReturn = nil
            } else {
                pending.candidate = candidate
                pendingReturn = pending
            }
        }
        Self.logger.info(
            "Revealing pane for 1Password request process=\(candidate.processName, privacy: .public) pid=\(candidate.pid, privacy: .public)"
        )
        hooks.reveal(candidate)
    }

#if DEBUG
    func pollForTesting() {
        poll()
    }
#endif
}
