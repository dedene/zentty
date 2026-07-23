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
}

// MARK: - Watcher token

/// Opaque handle for one connection's pane watches, returned by `addWatcher` and
/// used to fan `pane.text` back to that connection and to unregister on disconnect.
struct CompanionPaneWatchToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Feed

/// Streams `pane.text` for watched panes. On each coalesced `.contentChanged`
/// pulse for a watched pane it debounces `debounceInterval`, re-reads the pane
/// viewport through the provider, and pushes a monotonically-sequenced
/// `pane.text` to every connection watching that pane — skipping the send when
/// the text is byte-identical to the last snapshot. `pane.scrollback` is a
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
    /// Last text pushed per pane, for suppressing no-op re-reads.
    private var lastTextByPane: [String: String] = [:]
    /// Debounce generation per pane. Every `.contentChanged` bumps it; only the
    /// task carrying the current generation is allowed to emit, so a burst
    /// collapses to a single trailing-edge send without cancelling tasks.
    private var debounceGenByPane: [String: Int] = [:]

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

    /// Drops a connection entirely (disconnect): removes all its watches and
    /// re-evaluates the render-observation gate.
    func removeWatcher(_ token: CompanionPaneWatchToken) {
        guard watchers.removeValue(forKey: token) != nil else { return }
        syncObservation()
    }

    // MARK: pane.watch / pane.unwatch

    func watch(token: CompanionPaneWatchToken, paneId: String) {
        guard watchers[token] != nil else { return }
        watchers[token]?.paneIds.insert(paneId)
        syncObservation()
    }

    func unwatch(token: CompanionPaneWatchToken, paneId: String) {
        guard watchers[token]?.paneIds.remove(paneId) != nil else { return }
        if !isWatched(paneId) {
            // Last watcher gone: forget the pending debounce and snapshot so a
            // later rewatch re-sends current content (seq stays monotonic).
            debounceGenByPane[paneId] = nil
            lastTextByPane[paneId] = nil
        }
        syncObservation()
    }

    // MARK: Signals

    /// A coalesced render pulse for `paneId`. Debounces, then re-reads and emits.
    func handleContentChanged(paneId: String) {
        guard isWatched(paneId) else { return }
        let generation = (debounceGenByPane[paneId] ?? 0) + 1
        debounceGenByPane[paneId] = generation
        let interval = debounceInterval
        let sleep = self.sleep
        Task { [weak self] in
            try? await sleep(interval)
            guard let self else { return }
            guard self.debounceGenByPane[paneId] == generation else { return }
            self.debounceGenByPane[paneId] = nil
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
        debounceGenByPane[paneId] = nil
        lastTextByPane[paneId] = nil
        seqByPane[paneId] = nil
        if wasWatched {
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

        guard lastTextByPane[paneId] != readout.text else { return }

        let seq = (seqByPane[paneId] ?? 0) + 1
        seqByPane[paneId] = seq
        lastTextByPane[paneId] = readout.text

        let message = CompanionPaneText(
            paneId: paneId,
            seq: seq,
            viewport: readout.text,
            cursorRow: readout.cursorRow,
            gridCols: readout.gridCols,
            gridRows: readout.gridRows,
            truncatedScrollback: false
        )
        for target in targets {
            target.send(message)
        }
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
