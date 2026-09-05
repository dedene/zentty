import AppKit
import CoreGraphics
import Foundation
import os

/// One on-screen window, as much as we need to spot a 1Password prompt.
struct OnePasswordPromptWindow: Hashable, Sendable {
    let id: Int
    let ownerName: String
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
@MainActor
final class OnePasswordPromptFocusCoordinator {
    struct Hooks {
        let isEnabled: () -> Bool
        let sources: () -> [OnePasswordPromptPaneSource]
        /// Whether the pane is already the focused pane of its own window.
        let isPaneFocused: (OnePasswordPromptPaneSource) -> Bool
        let reveal: (OnePasswordPromptCandidate) -> Void
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
    }

    private func poll() {
        guard hooks.isEnabled() else {
            knownWindowIDs = nil
            return
        }
        if ticksUntilPresenceCheck == 0 {
            onePasswordPresent = isOnePasswordRunning()
            ticksUntilPresenceCheck = Self.presenceCheckTicks
        }
        ticksUntilPresenceCheck -= 1
        guard onePasswordPresent else {
            knownWindowIDs = nil
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
        guard let trigger = newPromptWindows.first else {
            return false
        }
        return startScan(reason: trigger.ownerName)
    }

    private func startScan(reason: String) -> Bool {
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
        let attributor = self.attributor
        scanExecutor { [weak self] in
            let candidate = attributor.bestCandidate(in: scannable)
            Task { @MainActor in
                self?.finishScan(generation: generation, candidate: candidate)
            }
        }
        return true
    }

    private func finishScan(generation: Int, candidate: OnePasswordPromptCandidate?) {
        guard generation == scanGeneration else { return }
        guard let candidate else {
            Self.logger.debug("No pane holds a live 1Password request")
            return
        }
        if hooks.isPaneFocused(candidate.source) {
            Self.logger.debug("1Password request pane already focused pid=\(candidate.pid, privacy: .public)")
            return
        }
        Self.logger.info(
            "Revealing pane for 1Password request process=\(candidate.processName, privacy: .public) pid=\(candidate.pid, privacy: .public)"
        )
        hooks.reveal(candidate)
    }
}
