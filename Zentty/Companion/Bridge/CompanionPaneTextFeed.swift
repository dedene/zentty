import Foundation
import OSLog

private let companionPaneTextLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionPaneText")

// MARK: - Text source seam

/// One viewport (or scrollback) read of a live pane. `@MainActor`-produced by
/// `AppDelegate` (resolve pane → `MainWindowController.readText` + `paneGridSize`);
/// faked in tests so the feed's debouncing, dedupe, and fan-out are exercisable
/// without real surfaces.
struct CompanionPaneTextReadout: Equatable, Sendable {
    var text: String
    var gridCols: Int
    var gridRows: Int
    var cursorRow: Int?
}

@MainActor
protocol CompanionPaneTextProviding: AnyObject {
    func companionReadPaneText(
        paneId: String,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> CompanionPaneTextReadout?

    /// Toggles a per-pane render keepalive so a mirrored pane keeps issuing render
    /// pulses even when its desktop surface would otherwise be occluded (a
    /// backgrounded pane, or one under a control-lease placeholder). Driven on the
    /// 0↔1 watcher edge for a pane; a no-op when the pane has no live surface.
    /// Without it an occluded surface stops repainting, so the phone's mirror
    /// (which is fed by render pulses) goes dark.
    func companionSetPaneRenderKeepAlive(paneId: String, active: Bool)
}

// MARK: - Watcher token

/// Opaque handle for one connection's pane watches, returned by `addWatcher` and
/// used to fan `pane.text` back to that connection and to unregister on disconnect.
struct CompanionPaneWatchToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Feed

/// Streams `pane.text` for watched panes. On each coalesced `.contentChanged`
/// pulse for a watched pane it throttles to `debounceInterval`, re-reads the pane
/// viewport through the provider, and pushes a monotonically-sequenced
/// `pane.text` to every connection watching that pane — skipping the send when
/// the readout (text + grid) is identical to the last snapshot. A newly joining
/// watcher also gets an immediate viewport snapshot so an idle pane is never
/// blank. `pane.scrollback` is a
/// one-shot full read. `@MainActor`: the provider reads the main-actor terminal
/// graph.
///
/// The feed also gates the app-wide render-observation flag
/// (`LibghosttyContentChangeObservation`): it is retained while at least one pane
/// is watched and released when the last watch goes away, so the hot render path
/// stays free when no phone is looking.
@MainActor
final class CompanionPaneTextFeed {
    static let defaultDebounce: TimeInterval = 0.15

    /// Debounce delay primitive, injectable so tests drive it with a virtual
    /// clock instead of wall-clock sleeps.
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private weak var provider: CompanionPaneTextProviding?
    private let debounceInterval: TimeInterval
    private let sleep: Sleep
    private let setObservationEnabled: (Bool) -> Void

    private struct Watcher {
        var paneIds: Set<String> = []
        let send: (CompanionPaneText) -> Void
    }
    private var watchers: [CompanionPaneWatchToken: Watcher] = [:]

    /// Monotonic sequence per pane. Persists across watch/unwatch so a rewatch
    /// keeps advancing; cleared only when the pane closes.
    private var seqByPane: [String: Int] = [:]
    /// Last readout pushed per pane, for suppressing no-op re-reads. Keyed on the
    /// whole readout (text + grid) so a reflow that keeps the text identical but
    /// changes the grid — e.g. a lease takeover pinning 51×28 — still emits.
    private var lastReadoutByPane: [String: CompanionPaneTextReadout] = [:]
    /// Panes with a throttle window in flight. While a pane is in this set,
    /// further `.contentChanged` pulses coalesce into the pending emit instead
    /// of postponing it — a trailing THROTTLE, not a debounce. A debounce here
    /// starves the phone during continuous output (streaming agents pulse
    /// faster than the interval, so the emit would never fire); the throttle
    /// guarantees a frame at most every `debounceInterval` and at least one
    /// per interval while output flows.
    private var throttlePendingPanes: Set<String> = []

    private var observationEnabled = false

    init(
        provider: CompanionPaneTextProviding,
        debounceInterval: TimeInterval = CompanionPaneTextFeed.defaultDebounce,
        sleep: @escaping Sleep = CompanionPaneTextFeed.realSleep,
        setObservationEnabled: @escaping (Bool) -> Void = { _ in }
    ) {
        self.provider = provider
        self.debounceInterval = debounceInterval
        self.sleep = sleep
        self.setObservationEnabled = setObservationEnabled
    }

    // MARK: Watcher lifecycle

    /// Registers a connection's `pane.text` sink. The returned token scopes its
    /// watches and is used to unregister on disconnect.
    func addWatcher(_ send: @escaping (CompanionPaneText) -> Void) -> CompanionPaneWatchToken {
        let token = CompanionPaneWatchToken(id: UUID())
        watchers[token] = Watcher(send: send)
        return token
    }

    /// Drops a connection entirely (disconnect): removes all its watches, releases
    /// the render keepalive on any pane it was the last watcher of, and
    /// re-evaluates the render-observation gate.
    func removeWatcher(_ token: CompanionPaneWatchToken) {
        guard let removed = watchers.removeValue(forKey: token) else { return }
        for paneId in removed.paneIds where !isWatched(paneId) {
            releaseUnwatchedPane(paneId)
        }
        syncObservation()
    }

    // MARK: pane.watch / pane.unwatch

    func watch(token: CompanionPaneWatchToken, paneId: String) {
        guard watchers[token] != nil else { return }
        let wasWatched = isWatched(paneId)
        guard watchers[token]?.paneIds.insert(paneId).inserted == true else { return }
        // First watcher on this pane: keep its surface rendering so it produces
        // the render pulses this feed streams from.
        if !wasWatched {
            provider?.companionSetPaneRenderKeepAlive(paneId: paneId, active: true)
        }
        // Immediately hand the joining watcher the current viewport. Without this
        // an idle pane (no render pulse coming) leaves a fresh watcher blank
        // forever; the send bypasses the shared dedupe so a second watcher joining
        // an already-primed, unchanged pane still gets its snapshot.
        if let send = watchers[token]?.send {
            sendInitialSnapshot(paneId: paneId, to: send)
        }
        syncObservation()
    }

    func unwatch(token: CompanionPaneWatchToken, paneId: String) {
        guard watchers[token]?.paneIds.remove(paneId) != nil else { return }
        if !isWatched(paneId) {
            releaseUnwatchedPane(paneId)
        }
        syncObservation()
    }

    /// The pane lost its last watcher: forget the pending debounce and snapshot so
    /// a later rewatch re-sends current content (seq stays monotonic), and drop the
    /// render keepalive so the surface can return to its occlusion-driven behavior.
    private func releaseUnwatchedPane(_ paneId: String) {
        throttlePendingPanes.remove(paneId)
        lastReadoutByPane[paneId] = nil
        provider?.companionSetPaneRenderKeepAlive(paneId: paneId, active: false)
    }

    // MARK: Signals

    /// A coalesced render pulse for `paneId`. Throttles, then re-reads and emits:
    /// the first pulse opens a window; pulses inside the window coalesce into
    /// the single emit that fires when it closes.
    func handleContentChanged(paneId: String) {
        guard isWatched(paneId) else { return }
        guard !throttlePendingPanes.contains(paneId) else { return }
        throttlePendingPanes.insert(paneId)
        let interval = debounceInterval
        let sleep = self.sleep
        Task { [weak self] in
            try? await sleep(interval)
            guard let self else { return }
            // Unwatch/close during the window cleared the pending flag; a
            // stale task must not emit or re-insert state for the pane.
            guard self.throttlePendingPanes.remove(paneId) != nil else { return }
            self.emitPaneText(paneId: paneId)
        }
    }

    /// The pane's surface closed. Drops every watch on it and clears its state.
    /// The phone is authoritatively told the pane is gone via the dashboard
    /// delta's `removedPaneIds`, so there is no separate wire notification here.
    func handlePaneClosed(paneId: String) {
        let wasWatched = isWatched(paneId)
        for token in watchers.keys {
            watchers[token]?.paneIds.remove(paneId)
        }
        throttlePendingPanes.remove(paneId)
        lastReadoutByPane[paneId] = nil
        seqByPane[paneId] = nil
        if wasWatched {
            provider?.companionSetPaneRenderKeepAlive(paneId: paneId, active: false)
            syncObservation()
        }
    }

    // MARK: pane.scrollback (one-shot)

    /// One full read of a pane's scrollback for a `pane.scrollback` request. The
    /// reply always carries `text` (empty when the pane has no live surface).
    func scrollback(paneId: String, lineLimit: Int?) -> CompanionPaneScrollback {
        let text = provider?.companionReadPaneText(
            paneId: paneId,
            includeScrollback: true,
            lineLimit: lineLimit
        )?.text ?? ""
        return CompanionPaneScrollback(paneId: paneId, text: text)
    }

    // MARK: Internals

    private func emitPaneText(paneId: String) {
        guard let provider else { return }
        let targets = watchers.values.filter { $0.paneIds.contains(paneId) }
        guard !targets.isEmpty else { return }

        guard let readout = provider.companionReadPaneText(
            paneId: paneId,
            includeScrollback: false,
            lineLimit: nil
        ) else {
            // No live surface right now (e.g. runtime not yet created). Skip
            // without closing the watch; a real close arrives via handlePaneClosed.
            return
        }

        guard lastReadoutByPane[paneId] != readout else { return }
        lastReadoutByPane[paneId] = readout

        let message = makePaneText(paneId: paneId, readout: readout)
        for target in targets {
            target.send(message)
        }
    }

    /// One-shot viewport read handed straight to a single joining watcher (not the
    /// shared fan-out). Bypasses the `lastReadoutByPane` dedupe on purpose so every
    /// new watcher gets a baseline frame, and deliberately does *not* update it —
    /// clobbering the shared snapshot here could suppress a pending debounced emit
    /// and starve the panes' existing watchers. A pane with no live surface yet
    /// sends nothing; the next content pulse delivers its first frame.
    private func sendInitialSnapshot(paneId: String, to send: (CompanionPaneText) -> Void) {
        guard let readout = provider?.companionReadPaneText(
            paneId: paneId,
            includeScrollback: false,
            lineLimit: nil
        ) else {
            return
        }
        send(makePaneText(paneId: paneId, readout: readout))
    }

    /// Builds a `pane.text` for the pane and advances its monotonic `seq`. Shared
    /// by the debounced fan-out and the per-watcher initial snapshot so both stamp
    /// frames identically.
    private func makePaneText(paneId: String, readout: CompanionPaneTextReadout) -> CompanionPaneText {
        let seq = (seqByPane[paneId] ?? 0) + 1
        seqByPane[paneId] = seq
        return CompanionPaneText(
            paneId: paneId,
            seq: seq,
            viewport: readout.text,
            cursorRow: readout.cursorRow,
            gridCols: readout.gridCols,
            gridRows: readout.gridRows,
            truncatedScrollback: false
        )
    }

    private func isWatched(_ paneId: String) -> Bool {
        watchers.values.contains { $0.paneIds.contains(paneId) }
    }

    /// Toggles the app-wide render-observation gate on the 0↔1 edge of "any pane
    /// watched", so retains and releases stay balanced.
    private func syncObservation() {
        let shouldObserve = watchers.values.contains { !$0.paneIds.isEmpty }
        guard shouldObserve != observationEnabled else { return }
        observationEnabled = shouldObserve
        setObservationEnabled(shouldObserve)
    }

    private static let realSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
