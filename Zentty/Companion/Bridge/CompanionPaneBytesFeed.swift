import Foundation
import OSLog

private let companionPaneBytesLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionPaneBytes")

// MARK: - Byte source seam

/// One coalesced run of raw PTY output for a pane, delivered on the main actor.
/// `seq` is the surface-absolute byte offset of `bytes[0]` within `epoch`.
typealias CompanionPaneBytesStreamSink = @MainActor (_ epoch: String, _ seq: Int, _ bytes: Data) -> Void

/// One screen capture of a pane as replayable VT bytes.
///
/// `data` written to a freshly reset emulator sized `cols`×`rows` reproduces the
/// screen — content, cursor, styles, alt-screen, scrolling region, and the modes
/// that change how LATER bytes are interpreted. `seq` is the absolute PTY offset
/// the capture reflects: every byte below it is already baked in, so the consumer
/// applies teed bytes at or after `seq` and discards anything below.
struct CompanionPaneSnapshot: Sendable {
    var data: Data
    var seq: Int
    var cols: Int
    var rows: Int
    /// The surface's stream epoch at capture time. Carried with the capture, not
    /// minted here: a cold attach to an already-running pane has no teed byte
    /// yet, so inventing a placeholder would make the first live chunk arrive
    /// under a different epoch and wipe the freshly-painted screen.
    var epoch: String
}

/// Producer seam for the raw-PTY lane: resolves a pane to its live surface and
/// installs/removes the libghostty PTY tee. `@MainActor`-implemented by
/// `AppDelegate` (pane → window controller → host view → adapter → surface);
/// faked in tests so the feed's install/remove edges are exercisable without a
/// real surface.
@MainActor
protocol CompanionPaneBytesProviding: AnyObject {
    /// Installs (or removes, with `nil`) the pane's PTY byte stream. Driven on the
    /// 0↔1 attached-watcher edge for a pane, so an unwatched Mac pays nothing on
    /// libghostty's io-reader thread.
    ///
    /// Returns `false` when the pane could not be resolved to a live surface, so
    /// the caller must not record it as streaming — otherwise the next attach is
    /// skipped as a duplicate and the phone waits forever for bytes that no tee
    /// will ever produce.
    @discardableResult
    func companionSetPaneByteStream(paneId: String, onBytes: CompanionPaneBytesStreamSink?) -> Bool

    /// Captures the pane's current screen as replayable VT bytes, resolving the
    /// pane to its live surface the same way the byte-stream install does.
    ///
    /// Returns `nil` when the pane has no live surface or the capture failed, in
    /// which case the caller falls back to a plain byte tail.
    ///
    /// EXPENSIVE: walks every active cell under libghostty's renderer mutex,
    /// blocking the io-reader thread — the same cost class as reading screen
    /// text. The feed throttles calls; never drive this per frame.
    func companionCapturePaneSnapshot(paneId: String) -> CompanionPaneSnapshot?
}

// MARK: - Watcher token

/// Opaque handle for one connection's pane.bytes subscriptions. Distinct from
/// `CompanionPaneWatchToken` (text lane) so the two paths do not share teardown.
struct CompanionPaneBytesToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Ring buffer

/// Fixed-capacity byte ring for warm-resume of `pane.bytes.*`. Stores the most
/// recent `capacity` bytes of a surface epoch and answers exclusive-end resume
/// queries (`fromSeq` = first missing byte on the phone).
///
/// Offsets are absolute within the epoch: the first byte ever written is at
/// offset 0, and `nextSeq` is always the exclusive end of written history
/// (whether or not older bytes have rolled off the ring).
struct CompanionPaneBytesRing: Sendable {
    /// Max retained bytes per epoch (1 MiB — covers a long scrollback of shell
    /// output while staying cheap in RAM for a handful of watched panes).
    static let defaultCapacity = 1 * 1024 * 1024

    /// True circular storage, preallocated to `capacity`. A shifting array would
    /// memmove the whole retained window on every append once full — ~1 MiB per
    /// 32 KiB chunk on the main actor, on top of the base64 and fan-out work in
    /// the same synchronous loop. Here a full ring costs one index bump.
    private let capacity: Int
    private var storage: [UInt8]
    /// Index of `baseSeq`'s byte within `storage`.
    private var head: Int = 0
    /// Bytes currently retained (`<= capacity`).
    private var count: Int = 0
    /// Absolute epoch offset of the oldest retained byte (increases as it rolls).
    private var baseSeq: Int = 0
    /// Absolute exclusive end of written bytes (next write lands at this offset).
    private(set) var nextSeq: Int = 0

    init(capacity: Int = CompanionPaneBytesRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    var isEmpty: Bool { nextSeq == baseSeq }

    /// Discards retained history and restarts the stream at an absolute offset.
    ///
    /// Used when the producer's authoritative `seq` does not continue our head:
    /// either the very first bytes of a lane (the surface has been running, so
    /// offsets start well past zero) or a real gap. Keeping the stale prefix would
    /// let a later cold attach hand the phone a tail with a hole in it.
    mutating func reset(toSeq seq: Int) {
        head = 0
        count = 0
        baseSeq = seq
        nextSeq = seq
    }

    mutating func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }

        // A write at least as large as the ring: keep only its tail.
        if bytes.count >= capacity {
            let tail = bytes.suffix(capacity)
            storage.withUnsafeMutableBufferPointer { dst in
                _ = tail.copyBytes(to: dst)
            }
            head = 0
            count = capacity
            nextSeq += bytes.count
            baseSeq = nextSeq - capacity
            return
        }

        // Copy into the ring, wrapping at most once.
        let writeIndex = (head + count) % capacity
        let firstRun = min(bytes.count, capacity - writeIndex)
        storage.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            bytes.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress else { return }
                dstBase.advanced(by: writeIndex).update(
                    from: srcBase.assumingMemoryBound(to: UInt8.self),
                    count: firstRun
                )
                if firstRun < bytes.count {
                    dstBase.update(
                        from: srcBase.advanced(by: firstRun).assumingMemoryBound(to: UInt8.self),
                        count: bytes.count - firstRun
                    )
                }
            }
        }

        nextSeq += bytes.count
        let overflow = max(0, count + bytes.count - capacity)
        count = min(count + bytes.count, capacity)
        if overflow > 0 {
            head = (head + overflow) % capacity
            baseSeq += overflow
        }
    }

    /// Bytes covering absolute range `[fromSeq, nextSeq)` when still in the ring.
    /// Returns `nil` when `fromSeq` has rolled off (`fromSeq < baseSeq`) or is
    /// ahead of the write head (`fromSeq > nextSeq`).
    func slice(fromSeq: Int) -> Data? {
        if fromSeq == nextSeq {
            return Data()
        }
        guard fromSeq >= baseSeq, fromSeq <= nextSeq else {
            return nil
        }
        return read(offset: fromSeq - baseSeq, length: nextSeq - fromSeq)
    }

    /// Full retained tail (cold attach replay).
    func tail() -> (startSeq: Int, data: Data) {
        (baseSeq, read(offset: 0, length: count))
    }

    /// Copies `length` retained bytes starting `offset` bytes past `baseSeq`,
    /// stitching across at most one wrap.
    private func read(offset: Int, length: Int) -> Data {
        guard length > 0 else { return Data() }
        let start = (head + offset) % capacity
        let firstRun = min(length, capacity - start)
        var out = Data(storage[start..<(start + firstRun)])
        if firstRun < length {
            out.append(contentsOf: storage[0..<(length - firstRun)])
        }
        return out
    }
}

// MARK: - Feed

/// Streams raw PTY bytes to phone watchers via `pane.bytes.chunk` and answers
/// `pane.bytes.attach` with ring replay. The producer side is fed through
/// ``ingest(paneId:epoch:bytes:)`` — typically a libghostty PTY tee callback
/// once available; tests inject synthetic bytes directly.
///
/// Multi-watcher: many connections may attach the same pane. Each live chunk
/// fans out to every attached token for that pane. Attach is request/reply per
/// connection (like scrollback), not a shared snapshot.
///
/// `lastSeq` on warm attach is the phone's exclusive resume cursor (first missing
/// byte). Non-truncated same-epoch replies use `startSeq == lastSeq`.
@MainActor
final class CompanionPaneBytesFeed {
    /// Decoded chunk size cap — mirrors `PANE_BYTES_MAX_CHUNK_BYTES` on the wire.
    static let maxChunkBytes = 32 * 1024

    /// Decoded replay cap — mirrors `PANE_BYTES_MAX_REPLAY_BYTES` on the wire.
    /// The ring is far larger than a single frame may be: base64, the session
    /// seal, and the relay's base64url framing together expand a replay by ~16/9,
    /// and the relay closes (1009) rather than rejects a frame over its 256 KiB
    /// cap. The binding constraint is tighter still — the relay's per-device
    /// *byte-rate* bucket has that same 256 KiB as its whole one-second capacity,
    /// so an attach big enough to fit the frame cap would starve the live chunks
    /// that follow it and stall the pane. One chunk's worth is the right budget.
    /// Replies past this cap carry the most recent bytes and `truncated`.
    static let maxReplayBytes = 32 * 1024

    /// Decoded screen-snapshot cap — mirrors `PANE_BYTES_MAX_SNAPSHOT_BYTES` on
    /// the wire. A snapshot rides in a frame that carries `replay: ""`, so the two
    /// caps are never charged against the same frame, and it is a one-shot attach
    /// cost rather than a steady-state one. A capture past this cap is dropped and
    /// the attach falls back to the tail-replay path — an oversize frame would
    /// make the relay close the socket (1009) instead of rejecting it.
    static let maxSnapshotBytes = 48 * 1024

    /// Minimum wall-clock gap between two screen captures of the SAME pane.
    ///
    /// Cold attach is user-driven and so naturally rare, but nothing stops a phone
    /// from re-attaching in a reconnect storm, and each capture holds libghostty's
    /// renderer mutex while it walks every active cell. Inside the window the
    /// attach falls back to a byte tail, which is exactly what it did before
    /// snapshots existed.
    static let minSnapshotInterval: TimeInterval = 1

    private struct Watcher {
        /// Panes this connection is currently attached to.
        var paneIds: Set<String> = []
        let sendChunk: (CompanionPaneBytesChunk) -> Void
    }

    private struct PaneState {
        var epoch: String
        var ring: CompanionPaneBytesRing
    }

    private var watchers: [CompanionPaneBytesToken: Watcher] = [:]
    private var panes: [String: PaneState] = [:]
    private let ringCapacity: Int
    private weak var provider: (any CompanionPaneBytesProviding)?
    /// Panes with a live PTY tee installed, so install/remove stay balanced on the
    /// 0↔1 attached-watcher edge.
    private var streamingPanes: Set<String> = []
    /// Wall clock of the last screen capture per pane, for the throttle.
    private var lastSnapshotAt: [String: Date] = [:]
    private let minSnapshotInterval: TimeInterval
    private let now: () -> Date

    init(
        provider: (any CompanionPaneBytesProviding)? = nil,
        ringCapacity: Int = CompanionPaneBytesRing.defaultCapacity,
        minSnapshotInterval: TimeInterval = CompanionPaneBytesFeed.minSnapshotInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.ringCapacity = ringCapacity
        self.minSnapshotInterval = minSnapshotInterval
        self.now = now
    }

    // MARK: Watcher lifecycle

    func addWatcher(sendChunk: @escaping (CompanionPaneBytesChunk) -> Void) -> CompanionPaneBytesToken {
        let token = CompanionPaneBytesToken(id: UUID())
        watchers[token] = Watcher(sendChunk: sendChunk)
        return token
    }

    func removeWatcher(_ token: CompanionPaneBytesToken) {
        guard let removed = watchers.removeValue(forKey: token) else { return }
        for paneId in removed.paneIds {
            releaseStreamIfUnattached(paneId)
        }
    }

    // MARK: Attach / detach

    /// Handles `pane.bytes.attach`. Registers the token for live chunks on success.
    func attach(
        token: CompanionPaneBytesToken,
        paneId: String,
        lastSeq: Int?,
        epoch: String?
    ) -> CompanionPaneBytesAttached {
        // Reject partial warm shapes (both required or both absent).
        let warm = lastSeq != nil || epoch != nil
        if warm && (lastSeq == nil || epoch == nil) {
            // Treat as cold: no reliable resume point.
            return coldAttach(token: token, paneId: paneId)
        }

        if let lastSeq, let epoch {
            return warmAttach(token: token, paneId: paneId, lastSeq: lastSeq, epoch: epoch)
        }
        return coldAttach(token: token, paneId: paneId)
    }

    func detach(token: CompanionPaneBytesToken, paneId: String) {
        guard var watcher = watchers[token] else { return }
        watcher.paneIds.remove(paneId)
        watchers[token] = watcher
        releaseStreamIfUnattached(paneId)
    }

    // MARK: Ingest (producer)

    /// Appends raw PTY output for a pane/epoch and fans chunks out to attached
    /// watchers.
    ///
    /// `seq` is AUTHORITATIVE: it is the producer's absolute byte offset of
    /// `bytes[0]` within `epoch` (libghostty's tee counter), not something this
    /// feed derives. That is what makes loss visible. Three cases:
    ///
    /// - `seq == ring.nextSeq` — contiguous, the normal path.
    /// - `seq > ring.nextSeq` — a GAP: the accumulator shed bytes under pressure,
    ///   or output flowed while no tee was installed. The ring restarts at `seq`,
    ///   so the chunk the phone receives carries a `seq` past its expected offset;
    ///   the phone warm re-attaches, the ring can no longer cover its cursor, and
    ///   it gets a `truncated` fresh tail and resets its emulator. Deriving `seq`
    ///   locally instead would keep the stream contiguous-looking and desync the
    ///   phone's emulator permanently.
    /// - `seq < ring.nextSeq` — bytes we already hold (a re-delivery); the
    ///   overlapping prefix is dropped so history stays consistent.
    ///
    /// A different `epoch` means the surface restarted: the ring is rebuilt at the
    /// new stream's offset.
    func ingest(paneId: String, epoch: String, seq: Int, bytes: Data) {
        guard !bytes.isEmpty, seq >= 0 else { return }

        var state = panes[paneId] ?? PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        if state.epoch != epoch {
            state = PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        }

        var payload = bytes
        var writeSeq = seq
        if state.ring.isEmpty {
            // Nothing retained for this epoch yet (fresh pane, or an epoch minted
            // by a cold attach before the first byte). Adopt the producer's offset
            // — a live surface's stream does not start at zero.
            state.ring.reset(toSeq: writeSeq)
        } else if writeSeq < state.ring.nextSeq {
            let overlap = state.ring.nextSeq - writeSeq
            guard overlap < payload.count else {
                panes[paneId] = state
                return
            }
            payload = Data(payload.dropFirst(overlap))
            writeSeq += overlap
        } else if writeSeq > state.ring.nextSeq {
            companionPaneBytesLogger.info(
                """
                pty stream gap: pane=\(paneId, privacy: .public) \
                expected=\(state.ring.nextSeq, privacy: .public) got=\(writeSeq, privacy: .public)
                """
            )
            state.ring.reset(toSeq: writeSeq)
        }

        var offset = 0
        while offset < payload.count {
            // Index off `startIndex`, not 0: a caller may hand us a slice-backed
            // `Data` whose indices do not start at zero.
            let sliceStart = payload.index(payload.startIndex, offsetBy: offset)
            let length = min(Self.maxChunkBytes, payload.count - offset)
            let sliceEnd = payload.index(sliceStart, offsetBy: length)
            let slice = Data(payload[sliceStart..<sliceEnd])
            let chunkSeq = state.ring.nextSeq
            state.ring.append(slice)
            fanOut(paneId: paneId, epoch: state.epoch, seq: chunkSeq, data: slice)
            offset += length
        }
        panes[paneId] = state
    }

    /// Surface closed or recreated: uninstall the tee, drop the ring so a later
    /// attach starts cold, and clear every watch on the pane.
    func handlePaneClosed(paneId: String) {
        panes.removeValue(forKey: paneId)
        lastSnapshotAt.removeValue(forKey: paneId)
        for (token, var watcher) in watchers {
            watcher.paneIds.remove(paneId)
            watchers[token] = watcher
        }
        // Unconditional (not edge-gated): the pane is gone, so the stream must go
        // with it even if bookkeeping ever drifted.
        if streamingPanes.remove(paneId) != nil {
            provider?.companionSetPaneByteStream(paneId: paneId, onBytes: nil)
        }
    }

    /// Mint or look up the current epoch for a pane (used by producers that need
    /// a stable id before the first byte arrives).
    func ensureEpoch(paneId: String, epoch: String) {
        if panes[paneId] == nil {
            panes[paneId] = PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        } else if panes[paneId]?.epoch != epoch {
            panes[paneId] = PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        }
    }

    // MARK: Private

    private func coldAttach(token: CompanionPaneBytesToken, paneId: String) -> CompanionPaneBytesAttached {
        markAttached(token: token, paneId: paneId)

        // A cold attacher has no emulator state at all, so a byte tail alone would
        // start mid-escape-sequence and miss every mode set before the retained
        // window. Repaint from a screen capture instead when one is available.
        if let snapshot = captureSnapshot(paneId: paneId) {
            adoptSnapshotEpoch(paneId: paneId, snapshot: snapshot)
            return snapshotReply(paneId: paneId, epoch: snapshot.epoch, snapshot: snapshot, truncated: false)
        }

        guard let state = panes[paneId] else {
            // No surface output yet — empty stream, mint a placeholder epoch so
            // the phone has a baseline; live chunks will arrive once ingest runs.
            let epoch = UUID().uuidString
            panes[paneId] = PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
            return CompanionPaneBytesAttached(
                paneId: paneId,
                epoch: epoch,
                startSeq: 0,
                replay: "",
                truncated: false
            )
        }
        let replay = Self.boundedReplay(paneId: paneId, tail: state.ring.tail())
        return CompanionPaneBytesAttached(
            paneId: paneId,
            epoch: state.epoch,
            startSeq: replay.startSeq,
            replay: replay.encoded,
            // Always `true` on a cold attach that falls back to a byte tail. A
            // tail is never a continuation of the receiver's state: it starts
            // mid-escape-sequence, so the phone MUST reset before writing it.
            // Reporting `false` here (because the tail happened to fit) let a
            // throttled re-attach paint garbage on top of a correct screen.
            truncated: true
        )
    }

    private func warmAttach(
        token: CompanionPaneBytesToken,
        paneId: String,
        lastSeq: Int,
        epoch: String
    ) -> CompanionPaneBytesAttached {
        markAttached(token: token, paneId: paneId)
        guard let state = panes[paneId], state.epoch == epoch else {
            // Epoch mismatch or unknown pane → truncated fresh tail (or empty).
            return truncatedReply(paneId: paneId)
        }
        if let data = state.ring.slice(fromSeq: lastSeq), data.count <= Self.maxReplayBytes {
            // Contiguous and inside one frame: a clean resume. The phone's
            // emulator is already correct, so no capture — splicing is both
            // cheaper and more faithful than a repaint.
            return CompanionPaneBytesAttached(
                paneId: paneId,
                epoch: state.epoch,
                startSeq: lastSeq,
                replay: data.base64EncodedString(),
                truncated: false
            )
        }
        // Either the ring rolled past `lastSeq` (or it is ahead of the head), or
        // the resumable gap does not fit one frame. Both mean the phone cannot
        // splice, so it must repaint — the same case as a cold attach.
        return truncatedReply(paneId: paneId)
    }

    private func truncatedReply(paneId: String) -> CompanionPaneBytesAttached {
        if let snapshot = captureSnapshot(paneId: paneId) {
            adoptSnapshotEpoch(paneId: paneId, snapshot: snapshot)
            return snapshotReply(paneId: paneId, epoch: snapshot.epoch, snapshot: snapshot, truncated: true)
        }
        if let state = panes[paneId] {
            let replay = Self.boundedReplay(paneId: paneId, tail: state.ring.tail())
            return CompanionPaneBytesAttached(
                paneId: paneId,
                epoch: state.epoch,
                startSeq: replay.startSeq,
                replay: replay.encoded,
                truncated: true
            )
        }
        let epoch = UUID().uuidString
        panes[paneId] = PaneState(epoch: epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        return CompanionPaneBytesAttached(
            paneId: paneId,
            epoch: epoch,
            startSeq: 0,
            replay: "",
            truncated: true
        )
    }

    /// Captures the pane's screen through the provider seam, subject to the
    /// per-pane throttle and the wire's decoded-size cap.
    ///
    /// Returns `nil` whenever the attach should fall back to a plain byte tail:
    /// no provider, an unresolvable pane, a failed capture, a capture inside the
    /// throttle window, or one too large for the wire.
    private func captureSnapshot(paneId: String) -> CompanionPaneSnapshot? {
        guard let provider else { return nil }

        let timestamp = now()
        if let last = lastSnapshotAt[paneId], timestamp.timeIntervalSince(last) < minSnapshotInterval {
            companionPaneBytesLogger.info(
                "snapshot throttled: pane=\(paneId, privacy: .public) falling back to byte tail"
            )
            return nil
        }

        guard let snapshot = provider.companionCapturePaneSnapshot(paneId: paneId) else { return nil }
        // Charge the throttle for any capture that actually ran, oversize or not:
        // the cost was paid under the renderer mutex either way.
        lastSnapshotAt[paneId] = timestamp

        guard snapshot.rows > 0, snapshot.cols > 0 else {
            companionPaneBytesLogger.error(
                "snapshot has empty grid: pane=\(paneId, privacy: .public)"
            )
            return nil
        }
        guard snapshot.data.count <= Self.maxSnapshotBytes else {
            companionPaneBytesLogger.error(
                """
                snapshot over wire cap: pane=\(paneId, privacy: .public) \
                bytes=\(snapshot.data.count, privacy: .public) falling back to byte tail
                """
            )
            return nil
        }
        return snapshot
    }

    /// Current epoch for a pane, minting a ring for it when the first attach beats
    /// the first byte. A snapshot reply needs an epoch even when nothing has been
    /// teed yet.
    /// Adopts the capture's own epoch as this pane's stream epoch, rebasing the
    /// ring to the capture point.
    ///
    /// The epoch MUST come from the surface, never be minted here. A cold attach
    /// to an already-running pane installs the tee at attach time, so no byte has
    /// been teed yet and there is no `PaneState`. Minting a placeholder meant the
    /// first real chunk arrived under libghostty's actual `ptyStreamEpoch`, the
    /// phone saw an epoch mismatch, and it wiped the screen the snapshot had just
    /// painted correctly — then hit the capture throttle on the retry and fell
    /// back to a garbage byte tail. Exactly the flagship case.
    private func adoptSnapshotEpoch(paneId: String, snapshot: CompanionPaneSnapshot) {
        var state = panes[paneId] ?? PaneState(
            epoch: snapshot.epoch,
            ring: CompanionPaneBytesRing(capacity: ringCapacity)
        )
        if state.epoch != snapshot.epoch {
            state = PaneState(epoch: snapshot.epoch, ring: CompanionPaneBytesRing(capacity: ringCapacity))
        }
        // Everything below the capture point is already baked into the snapshot,
        // so the ring restarts there rather than replaying it.
        state.ring.reset(toSeq: snapshot.seq)
        panes[paneId] = state
    }

    /// Reply carrying a screen capture. `replay` is always empty and `startSeq` is
    /// the capture's own offset: the snapshot is excluded from seq arithmetic, so
    /// the phone's next expected chunk offset is exactly `startSeq`. Shipping the
    /// ring tail alongside would double-apply bytes already baked into the capture.
    private func snapshotReply(
        paneId: String,
        epoch: String,
        snapshot: CompanionPaneSnapshot,
        truncated: Bool
    ) -> CompanionPaneBytesAttached {
        CompanionPaneBytesAttached(
            paneId: paneId,
            epoch: epoch,
            startSeq: snapshot.seq,
            replay: "",
            truncated: truncated,
            snapshot: snapshot.data.base64EncodedString(),
            snapshotRows: snapshot.rows,
            snapshotCols: snapshot.cols
        )
    }

    /// Clamps a replay tail to ``maxReplayBytes``, keeping the most RECENT bytes
    /// and advancing `startSeq` past the dropped prefix. `dropped` is true when
    /// bytes were shed, which the caller reports as `truncated` so the phone
    /// resets its emulator instead of splicing a non-contiguous tail.
    private static func boundedReplay(
        paneId: String,
        tail: (startSeq: Int, data: Data)
    ) -> (startSeq: Int, encoded: String, dropped: Bool) {
        guard tail.data.count > maxReplayBytes else {
            return (tail.startSeq, tail.data.base64EncodedString(), false)
        }
        let shed = tail.data.count - maxReplayBytes
        companionPaneBytesLogger.info(
            "replay clamped to wire cap: pane=\(paneId, privacy: .public) dropped=\(shed, privacy: .public)"
        )
        return (
            tail.startSeq + shed,
            Data(tail.data.suffix(maxReplayBytes)).base64EncodedString(),
            true
        )
    }

    private func markAttached(token: CompanionPaneBytesToken, paneId: String) {
        guard var watcher = watchers[token] else {
            companionPaneBytesLogger.error("attach for unknown token")
            return
        }
        watcher.paneIds.insert(paneId)
        watchers[token] = watcher
        installStreamIfNeeded(paneId)
    }

    /// True while any connection is attached to this pane's byte lane.
    private func isAttached(_ paneId: String) -> Bool {
        watchers.values.contains { $0.paneIds.contains(paneId) }
    }

    /// First attach on the pane: start teeing its PTY into this feed.
    ///
    /// Only records the pane as streaming once the provider confirms the tee
    /// landed. A pane that cannot be resolved yet (its window still restoring)
    /// must stay retryable — recording it would make every later attach a no-op
    /// and leave the phone showing a permanently frozen mirror, because its
    /// resync is only ever driven by an arriving chunk.
    private func installStreamIfNeeded(_ paneId: String) {
        guard !streamingPanes.contains(paneId) else { return }
        guard let provider else { return }

        if provider.companionSetPaneByteStream(paneId: paneId, onBytes: { [weak self] epoch, seq, bytes in
            self?.ingest(paneId: paneId, epoch: epoch, seq: seq, bytes: bytes)
        }) {
            streamingPanes.insert(paneId)
        } else {
            // The pane no longer resolves to a surface. Any ring we still hold for
            // it describes a dead pane, and answering a warm attach from it would
            // hand the phone stale bytes with `truncated: false`. Drop it.
            panes.removeValue(forKey: paneId)
        }
    }

    /// Last watcher gone: uninstall the tee. The ring is kept — offsets are
    /// absolute, so bytes that flow untee'd surface as a gap on the next attach
    /// rather than as silently spliced output.
    ///
    /// Unless the pane itself is gone. A user-initiated pane close (Cmd-W) does
    /// not route through `handlePaneClosed` — only shell exit does — so without
    /// this a closed-but-watched pane would strand its 1 MiB ring for the life of
    /// the process, and still answer a later warm attach with stale bytes.
    private func releaseStreamIfUnattached(_ paneId: String) {
        guard !isAttached(paneId) else { return }
        guard streamingPanes.remove(paneId) != nil else { return }
        guard let provider else { return }
        if !provider.companionSetPaneByteStream(paneId: paneId, onBytes: nil) {
            panes.removeValue(forKey: paneId)
        }
    }

    private func fanOut(paneId: String, epoch: String, seq: Int, data: Data) {
        let chunk = CompanionPaneBytesChunk(
            paneId: paneId,
            epoch: epoch,
            seq: seq,
            data: data.base64EncodedString()
        )
        for watcher in watchers.values where watcher.paneIds.contains(paneId) {
            watcher.sendChunk(chunk)
        }
    }
}
