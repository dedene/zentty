import Foundation
import OSLog

private let companionLeaseLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionLease")

// MARK: - Takeover applier seam

/// The single pane-side primitive the lease manager drives: apply a fixed-grid
/// takeover to a pane (occlude the desktop surface, fix its grid to cols×rows,
/// show the "controlled by <device>" placeholder with a Take Back Control button
/// wired to `onTakeBack`), and restore it to its layout-derived size. Implemented
/// by `AppDelegate` (resolve pane → window controller → terminal host view);
/// faked in tests so the manager's lease bookkeeping is exercisable without a
/// live surface.
@MainActor
protocol CompanionLeaseTakeoverApplying: AnyObject {
    /// Applies (or refreshes, on resize/supersede) a control-lease takeover on the
    /// pane. Idempotent: a second call for a pane already under lease updates the
    /// grid and placeholder in place. Returns `false` when the pane can't be
    /// resolved (unknown id / no live surface); the manager still grants, so a
    /// stuck placeholder is impossible by construction.
    @discardableResult
    func companionApplyLeaseTakeover(
        paneId: String,
        cols: Int,
        rows: Int,
        deviceName: String,
        onTakeBack: @escaping () -> Void
    ) -> Bool

    /// Restores the pane to its layout-derived size, removes the placeholder, and
    /// re-enables desktop rendering. A no-op when the pane is already gone.
    func companionRestoreLeasedPane(paneId: String)
}

// MARK: - Client token

/// Opaque handle for one connection's lease participation, returned by
/// `addClient` and used to route `lease.revoked` back to that connection and to
/// detach it on disconnect.
struct CompanionLeaseClientToken: Hashable, Sendable {
    fileprivate let id: UUID
}

// MARK: - Lease manager

/// Grants, renews, resizes, and expires per-pane control leases (spec §2.6).
///
/// Invariants:
/// - **Single holder per pane.** A fresh `lease.request` supersedes any current
///   holder, revoking it with `superseded`.
/// - **Grant unconditionally, clamp only.** The phone-measured grid is granted
///   after a sanity clamp (20–500 cols × 5–200 rows). `effective` is the clamped
///   grid; `client` the raw request; `isCurrentClientLimiting` is true iff the
///   clamp changed nothing (the client's own grid is what constrains the surface).
/// - **Heartbeats, not connections.** A lease lives while heartbeats arrive
///   (expiry 15s after the last one). A transport blip is treated as missed
///   heartbeats — the expiry timer keeps running; a disconnect never drops the
///   lease instantly. A reconnecting phone that heartbeats the same `leaseId`
///   rebinds delivery to its new connection.
/// - **Desktop always wins.** `takeBack` reclaims immediately.
/// - **Nothing persists.** All state is in memory; `revokeAll` (app teardown)
///   ends every lease and restores every pane.
///
/// The 15s expiry and 300ms resize debounce run on injectable `sleep`/`now`
/// seams so tests drive them with a virtual clock instead of wall time.
@MainActor
final class CompanionLeaseManager {
    static let minCols = 20
    static let maxCols = 500
    static let minRows = 5
    static let maxRows = 200
    static let heartbeatIntervalMs = 5000
    static let expiryMs = 15000
    static let expiryInterval: TimeInterval = 15
    static let resizeDebounceInterval: TimeInterval = 0.3

    /// Delay primitive; injectable so tests advance a virtual clock instead of
    /// sleeping on wall time.
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    /// Monotonic seconds source, paired with `Sleep`: a woken expiry loop measures
    /// idle time against `now()` rather than assuming a full interval elapsed, so
    /// heartbeats that land mid-sleep extend the lease precisely.
    typealias Clock = @Sendable () -> TimeInterval

    private weak var applier: CompanionLeaseTakeoverApplying?
    private let sleep: Sleep
    private let now: Clock

    private struct Client {
        let send: (CompanionLeaseRevoked) -> Void
    }
    private var clients: [CompanionLeaseClientToken: Client] = [:]

    private struct Lease {
        let leaseId: String
        let paneId: String
        var clientToken: CompanionLeaseClientToken
        var deviceName: String
        var effective: CompanionGrid
        var lastHeartbeat: TimeInterval
    }
    /// Single holder per pane.
    private var leasesByPane: [String: Lease] = [:]
    private var paneIdByLeaseId: [String: String] = [:]
    /// Expiry-loop generation per lease. Bumped when a lease ends so the running
    /// loop exits; heartbeats do *not* bump it (they just move `lastHeartbeat`).
    private var expiryGenByLease: [String: Int] = [:]
    /// Resize-debounce generation per lease; only the latest scheduled apply fires.
    private var resizeGenByLease: [String: Int] = [:]

    init(
        applier: CompanionLeaseTakeoverApplying?,
        sleep: @escaping Sleep = CompanionLeaseManager.realSleep,
        now: @escaping Clock = CompanionLeaseManager.realClock
    ) {
        self.applier = applier
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Client lifecycle

    /// Registers a connection's `lease.revoked` sink; the token routes revocations
    /// back and rebinds on heartbeat.
    func addClient(_ send: @escaping (CompanionLeaseRevoked) -> Void) -> CompanionLeaseClientToken {
        let token = CompanionLeaseClientToken(id: UUID())
        clients[token] = Client(send: send)
        return token
    }

    /// Detaches a connection (disconnect). The lease itself is *not* dropped —
    /// disconnect is treated as missed heartbeats, so the expiry timer keeps
    /// running and a transient blip can't strand the pane. A reconnecting phone
    /// heartbeating the same `leaseId` rebinds delivery to its new token.
    func removeClient(_ token: CompanionLeaseClientToken) {
        clients[token] = nil
    }

    // MARK: - lease.request

    /// Grants a lease for `paneId`, superseding any current holder. Always grants
    /// (clamp only); applies the takeover to the pane.
    func request(
        token: CompanionLeaseClientToken,
        paneId: String,
        cols: Int,
        rows: Int,
        deviceName: String
    ) -> CompanionLeaseGrant {
        let client = CompanionGrid(cols: cols, rows: rows)
        let effective = Self.clamp(cols: cols, rows: rows)
        let isCurrentClientLimiting = (effective == client)

        // Single-holder rule: a new request supersedes the current holder without
        // restoring the pane in between — the new grid is applied immediately.
        if let existing = leasesByPane[paneId] {
            revokeLease(existing.leaseId, reason: .superseded, restore: false)
        }

        let leaseId = UUID().uuidString
        let lease = Lease(
            leaseId: leaseId,
            paneId: paneId,
            clientToken: token,
            deviceName: deviceName,
            effective: effective,
            lastHeartbeat: now()
        )
        leasesByPane[paneId] = lease
        paneIdByLeaseId[leaseId] = paneId

        applier?.companionApplyLeaseTakeover(
            paneId: paneId,
            cols: effective.cols,
            rows: effective.rows,
            deviceName: deviceName,
            onTakeBack: { [weak self] in self?.takeBack(paneId: paneId) }
        )
        armExpiry(leaseId: leaseId)

        companionLeaseLogger.info(
            "Granted lease \(leaseId, privacy: .public) for pane \(paneId, privacy: .public) at \(effective.cols)x\(effective.rows)"
        )
        return CompanionLeaseGrant(
            paneId: paneId,
            leaseId: leaseId,
            effective: effective,
            client: client,
            isCurrentClientLimiting: isCurrentClientLimiting,
            heartbeatIntervalMs: Self.heartbeatIntervalMs,
            expiryMs: Self.expiryMs
        )
    }

    // MARK: - lease.heartbeat

    /// Renews a lease and rebinds delivery to the heartbeating connection (so a
    /// reconnect keeps receiving revocations). Unknown / stale ids are ignored.
    func heartbeat(token: CompanionLeaseClientToken, leaseId: String) {
        guard let paneId = paneIdByLeaseId[leaseId], var lease = leasesByPane[paneId] else { return }
        lease.lastHeartbeat = now()
        lease.clientToken = token
        leasesByPane[paneId] = lease
    }

    // MARK: - lease.resize

    /// Re-requests the grid on rotation / font change, debounced 300ms. Re-clamps,
    /// re-applies the surface size in place, and counts as a sign of life.
    func resize(leaseId: String, cols: Int, rows: Int) {
        guard paneIdByLeaseId[leaseId] != nil else { return }
        let generation = (resizeGenByLease[leaseId] ?? 0) + 1
        resizeGenByLease[leaseId] = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.resizeDebounceInterval)
            guard self.resizeGenByLease[leaseId] == generation else { return }
            self.resizeGenByLease[leaseId] = nil
            self.applyResize(leaseId: leaseId, cols: cols, rows: rows)
        }
    }

    private func applyResize(leaseId: String, cols: Int, rows: Int) {
        guard let paneId = paneIdByLeaseId[leaseId], var lease = leasesByPane[paneId] else { return }
        let effective = Self.clamp(cols: cols, rows: rows)
        lease.effective = effective
        lease.lastHeartbeat = now()
        leasesByPane[paneId] = lease
        applier?.companionApplyLeaseTakeover(
            paneId: paneId,
            cols: effective.cols,
            rows: effective.rows,
            deviceName: lease.deviceName,
            onTakeBack: { [weak self] in self?.takeBack(paneId: paneId) }
        )
    }

    // MARK: - lease.release / end paths

    /// Phone-initiated release: restore the pane. No `lease.revoked` — the phone
    /// already knows.
    func release(leaseId: String) {
        revokeLease(leaseId, reason: nil, restore: true)
    }

    /// Desktop reclaim (placeholder "Take Back Control" button): revoke + restore.
    func takeBack(paneId: String) {
        guard let lease = leasesByPane[paneId] else { return }
        revokeLease(lease.leaseId, reason: .takeback, restore: true)
    }

    /// The pane's surface closed: revoke the holder. Restore is a harmless no-op
    /// on a gone pane.
    func handlePaneClosed(paneId: String) {
        guard let lease = leasesByPane[paneId] else { return }
        revokeLease(lease.leaseId, reason: .paneClosed, restore: true)
    }

    /// App teardown (`stop()`): end every lease and restore every pane. Nothing is
    /// persisted, so there is nothing to restore on relaunch.
    func revokeAll() {
        for leaseId in Array(paneIdByLeaseId.keys) {
            revokeLease(leaseId, reason: .takeback, restore: true)
        }
    }

    // MARK: - Internals

    /// Clamps a phone-measured grid to the sanity range.
    private static func clamp(cols: Int, rows: Int) -> CompanionGrid {
        CompanionGrid(
            cols: min(max(cols, minCols), maxCols),
            rows: min(max(rows, minRows), maxRows)
        )
    }

    /// Ends a lease exactly once: kills its expiry/resize loops, forgets it,
    /// optionally notifies the holder, and optionally restores the pane.
    private func revokeLease(
        _ leaseId: String,
        reason: CompanionLeaseRevokedReason?,
        restore: Bool
    ) {
        guard let paneId = paneIdByLeaseId[leaseId], let lease = leasesByPane[paneId] else { return }
        expiryGenByLease[leaseId] = nil
        resizeGenByLease[leaseId] = nil
        leasesByPane[paneId] = nil
        paneIdByLeaseId[leaseId] = nil

        if let reason {
            clients[lease.clientToken]?.send(CompanionLeaseRevoked(leaseId: leaseId, reason: reason))
        }
        if restore {
            applier?.companionRestoreLeasedPane(paneId: paneId)
        }
        companionLeaseLogger.info(
            "Ended lease \(leaseId, privacy: .public) for pane \(paneId, privacy: .public) reason=\(reason?.rawValue ?? "release", privacy: .public)"
        )
    }

    /// Runs one expiry loop per lease: sleep for the remaining time-to-expiry, then
    /// re-measure against `now()`. Heartbeats move `lastHeartbeat` forward, so a
    /// woken loop simply re-arms for the new remaining window; only a genuinely
    /// idle lease (≥15s since the last heartbeat) expires. The generation guard
    /// makes an ended lease exit and guarantees a single expiry.
    private func armExpiry(leaseId: String) {
        let generation = (expiryGenByLease[leaseId] ?? 0) + 1
        expiryGenByLease[leaseId] = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.expiryGenByLease[leaseId] == generation,
                  let paneId = self.paneIdByLeaseId[leaseId],
                  let lease = self.leasesByPane[paneId] {
                let remaining = Self.expiryInterval - (self.now() - lease.lastHeartbeat)
                if remaining <= 0 {
                    self.revokeLease(leaseId, reason: .expired, restore: true)
                    return
                }
                try? await self.sleep(remaining)
            }
        }
    }

    private static let realSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private static let realClock: Clock = {
        Date().timeIntervalSinceReferenceDate
    }
}
