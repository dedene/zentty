import Foundation
import OSLog

private let companionTranscriptLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionTranscript")

// MARK: - Resolution seam

/// Everything the feed needs to locate a pane's session file: the tool (which
/// adapter to use), the tracked session id + working directory (for the
/// canonical fallback path), and the live path the running agent reported.
/// `@MainActor`-produced by `AppDelegate` (walk the discovery graph to the
/// pane's `PaneAgentStatus`); faked in tests.
struct CompanionTranscriptTarget: Equatable, Sendable {
    var tool: AgentTool
    var sessionID: String?
    var workingDirectory: String?
    var liveTranscriptPath: String?
}

@MainActor
protocol CompanionTranscriptSourceProviding: AnyObject {
    func companionTranscriptTarget(forPaneId paneId: String) -> CompanionTranscriptTarget?
}

// MARK: - File-watch seam

/// A change on a tailed transcript file. `.vanished` covers delete/rename, which
/// is how a session rotation (agent restart → new session id → new file) surfaces.
enum CompanionTranscriptFileEvent: Sendable {
    case changed
    case vanished
}

/// A live file watch; cancelled when the last subscriber for the pane goes away.
@MainActor
protocol CompanionTranscriptFileWatch: AnyObject {
    func cancel()
}

/// Builds a file watch for `url`, invoking `onEvent` on the main actor for every
/// write/extend and once for delete/rename. Injected so tests drive events
/// synchronously instead of racing `DispatchSource`.
typealias CompanionTranscriptWatcherFactory = @MainActor (
    _ url: URL,
    _ onEvent: @escaping @MainActor (CompanionTranscriptFileEvent) -> Void
) -> CompanionTranscriptFileWatch?

// MARK: - Delivery

/// What a subscribed connection receives after its initial snapshot/unavailable.
enum CompanionTranscriptEvent: Sendable {
    case delta(CompanionTranscriptDelta)
    case unavailable(CompanionTranscriptUnavailable)
}

/// The synchronous reply to a `transcript.subscribe`.
enum CompanionTranscriptSubscribeReply: Sendable {
    case snapshot(CompanionTranscriptSnapshot)
    case unavailable(CompanionTranscriptUnavailable)
}

/// Opaque handle for one connection's transcript subscriptions.
struct CompanionTranscriptSubscriberToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Feed

/// Serves `transcript.*` for panes whose tool has an adapter. On subscribe it
/// resolves the session file, reads a bounded snapshot (last `snapshotLimit`
/// entries), and tails the file: each write is parsed into a `transcript.delta`,
/// and a delete/rename becomes `transcript.unavailable(session_ended)`.
///
/// `@MainActor`: it reads the discovery graph through the source provider and
/// fans results back to main-actor sessions.
@MainActor
final class CompanionTranscriptFeed {
    static let defaultSnapshotLimit = 200

    private weak var source: CompanionTranscriptSourceProviding?
    private let registry: CompanionTranscriptAdapterRegistry
    private let snapshotLimit: Int
    private let watcherFactory: CompanionTranscriptWatcherFactory
    private let fileManager: FileManager

    private struct Subscriber {
        var paneIds: Set<String> = []
        let send: (CompanionTranscriptEvent) -> Void
    }
    private var subscribers: [CompanionTranscriptSubscriberToken: Subscriber] = [:]

    /// One tailed file per pane, shared by every connection watching it.
    private final class PaneTail {
        let url: URL
        let sessionId: String
        let scanner: CompanionTranscriptScanner
        var offset: UInt64
        var watch: CompanionTranscriptFileWatch?

        init(url: URL, sessionId: String, scanner: CompanionTranscriptScanner, offset: UInt64) {
            self.url = url
            self.sessionId = sessionId
            self.scanner = scanner
            self.offset = offset
        }
    }
    private var tails: [String: PaneTail] = [:]

    init(
        source: CompanionTranscriptSourceProviding,
        registry: CompanionTranscriptAdapterRegistry = .default,
        snapshotLimit: Int = CompanionTranscriptFeed.defaultSnapshotLimit,
        watcherFactory: @escaping CompanionTranscriptWatcherFactory = CompanionTranscriptFeed.dispatchSourceWatcher,
        fileManager: FileManager = .default
    ) {
        self.source = source
        self.registry = registry
        self.snapshotLimit = snapshotLimit
        self.watcherFactory = watcherFactory
        self.fileManager = fileManager
    }

    // MARK: Subscriber lifecycle

    func addSubscriber(_ send: @escaping (CompanionTranscriptEvent) -> Void) -> CompanionTranscriptSubscriberToken {
        let token = CompanionTranscriptSubscriberToken(id: UUID())
        subscribers[token] = Subscriber(send: send)
        return token
    }

    /// Drops a connection entirely (disconnect): removes its watches and tears
    /// down any pane tail that no longer has an interested connection.
    func removeSubscriber(_ token: CompanionTranscriptSubscriberToken) {
        guard let subscriber = subscribers.removeValue(forKey: token) else { return }
        for paneId in subscriber.paneIds {
            teardownTailIfUnwatched(paneId)
        }
    }

    // MARK: transcript.subscribe

    /// Resolves the pane's session file and returns the initial snapshot (or an
    /// unavailable reason). On success the token is registered for the pane and
    /// the file is tailed for deltas.
    func subscribe(token: CompanionTranscriptSubscriberToken, paneId: String) -> CompanionTranscriptSubscribeReply {
        guard subscribers[token] != nil else {
            return .unavailable(CompanionTranscriptUnavailable(paneId: paneId, reason: .noAdapter))
        }

        guard
            let target = source?.companionTranscriptTarget(forPaneId: paneId),
            let adapter = registry.adapter(for: target.tool)
        else {
            return .unavailable(CompanionTranscriptUnavailable(paneId: paneId, reason: .noAdapter))
        }

        guard let url = adapter.transcriptURL(
            sessionID: target.sessionID,
            workingDirectory: target.workingDirectory,
            liveTranscriptPath: target.liveTranscriptPath
        ), fileManager.fileExists(atPath: url.path) else {
            return .unavailable(CompanionTranscriptUnavailable(paneId: paneId, reason: .fileMissing))
        }

        let sessionId = target.sessionID ?? url.deletingPathExtension().lastPathComponent

        // (Re)build the tail on the first watcher for this pane, or when the
        // resolved file changed (rotation while unwatched). A subscribe always
        // reads the file fresh for its snapshot.
        let tail: PaneTail
        if let existing = tails[paneId], existing.url == url {
            tail = existing
        } else {
            tails[paneId]?.watch?.cancel()
            tail = PaneTail(url: url, sessionId: sessionId, scanner: adapter.makeScanner(), offset: 0)
            tails[paneId] = tail
            startWatch(for: paneId, tail: tail)
        }

        subscribers[token]?.paneIds.insert(paneId)

        let (entries, truncated) = snapshotEntries(for: tail)
        return .snapshot(CompanionTranscriptSnapshot(
            paneId: paneId,
            sessionId: tail.sessionId,
            truncated: truncated,
            entries: entries
        ))
    }

    // MARK: Signals

    /// The pane's surface closed. Stops tailing and forgets the file; the phone
    /// learns the pane is gone via the dashboard delta's `removedPaneIds`.
    func handlePaneClosed(paneId: String) {
        guard let tail = tails.removeValue(forKey: paneId) else { return }
        tail.watch?.cancel()
        for token in subscribers.keys {
            subscribers[token]?.paneIds.remove(paneId)
        }
    }

    // MARK: Internals

    /// Reads the whole file through a throwaway scanner to build the snapshot,
    /// leaving the live tail's offset/scanner untouched (the tail already spans
    /// the same bytes for deltas).
    private func snapshotEntries(for tail: PaneTail) -> (entries: [CompanionTranscriptEntry], truncated: Bool) {
        guard let data = try? Data(contentsOf: tail.url) else { return ([], false) }
        // Seed the live tail so the first delta only carries bytes appended after
        // this snapshot.
        if tail.offset == 0 {
            _ = tail.scanner.consume(data)
            tail.offset = UInt64(data.count)
        }
        let all = ClaudeTranscriptTail().consume(data)
        guard all.count > snapshotLimit else { return (all, false) }
        return (Array(all.suffix(snapshotLimit)), true)
    }

    private func startWatch(for paneId: String, tail: PaneTail) {
        tail.watch = watcherFactory(tail.url) { [weak self] event in
            self?.handleFileEvent(event, paneId: paneId)
        }
    }

    private func handleFileEvent(_ event: CompanionTranscriptFileEvent, paneId: String) {
        guard let tail = tails[paneId] else { return }
        switch event {
        case .changed:
            emitDelta(for: paneId, tail: tail)
        case .vanished:
            broadcast(.unavailable(CompanionTranscriptUnavailable(paneId: paneId, reason: .sessionEnded)), paneId: paneId)
            tail.watch?.cancel()
            tails[paneId] = nil
            // Keep the token → pane registration so a later re-subscribe (new
            // session id) rebuilds the tail; only a disconnect clears it.
        }
    }

    private func emitDelta(for paneId: String, tail: PaneTail) {
        guard let handle = try? FileHandle(forReadingFrom: tail.url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: tail.offset)
        } catch {
            return
        }
        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty else { return }
        tail.offset += UInt64(newData.count)

        let entries = tail.scanner.consume(newData)
        guard !entries.isEmpty else { return }
        broadcast(.delta(CompanionTranscriptDelta(paneId: paneId, entries: entries)), paneId: paneId)
    }

    private func broadcast(_ event: CompanionTranscriptEvent, paneId: String) {
        for subscriber in subscribers.values where subscriber.paneIds.contains(paneId) {
            subscriber.send(event)
        }
    }

    private func teardownTailIfUnwatched(_ paneId: String) {
        let stillWatched = subscribers.values.contains { $0.paneIds.contains(paneId) }
        guard !stillWatched, let tail = tails.removeValue(forKey: paneId) else { return }
        tail.watch?.cancel()
    }

    // MARK: DispatchSource watcher (production)

    /// Production watcher: an `O_EVTONLY` `DispatchSource` on the file, delivering
    /// on the main queue. Delete/rename ends the watch as `.vanished`.
    static let dispatchSourceWatcher: CompanionTranscriptWatcherFactory = { url, onEvent in
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            companionTranscriptLogger.error("Failed to open transcript for watching: \(url.path, privacy: .private)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler {
            let flags = source.data
            let vanished = !flags.intersection([.delete, .rename, .revoke]).isEmpty
            MainActorShim.assumeIsolated {
                onEvent(vanished ? .vanished : .changed)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return DispatchSourceTranscriptWatch(source: source)
    }
}

/// Retains a `DispatchSource` file watch and cancels it on request.
@MainActor
private final class DispatchSourceTranscriptWatch: CompanionTranscriptFileWatch {
    private let source: DispatchSourceFileSystemObject
    private var cancelled = false

    init(source: DispatchSourceFileSystemObject) {
        self.source = source
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        source.cancel()
    }
}
