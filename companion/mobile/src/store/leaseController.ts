/**
 * Phone-side control-lease state machine (spec §2.6), mirroring the Mac's
 * `CompanionLeaseManager`.
 *
 * Lifecycle: `request(cols,rows)` → `lease.grant` → hold with a heartbeat every
 * `heartbeatIntervalMs`, `resize` on rotation/font (debounced 300ms), `release`
 * on leaving. A `lease.revoked` (takeback/expired/pane_closed/superseded) drops
 * the phone to a read-only mirror with the reason retained for the UI.
 *
 * All timers are injectable so the heartbeat schedule and resize debounce are
 * driven by a virtual clock in tests.
 */

import type { LeaseRevokedReason, ViewportSize } from '@zentty/wire';

export type LeaseStatus = 'idle' | 'requesting' | 'held' | 'readonly';

/** The lease-grant fields the phone keeps (mirrors the wire `LeaseGrant`). */
export interface LeaseGrantData {
  leaseId: string;
  effective: ViewportSize;
  client: ViewportSize;
  isCurrentClientLimiting: boolean;
  heartbeatIntervalMs: number;
  expiryMs: number;
}

/** Serializable lease snapshot the store holds and the screen renders. */
export interface LeaseSnapshot {
  status: LeaseStatus;
  leaseId?: string;
  /** Grid the Mac actually applied (clamped). */
  effective?: ViewportSize;
  /** Grid the phone requested (pre-clamp). */
  client?: ViewportSize;
  isCurrentClientLimiting?: boolean;
  heartbeatIntervalMs?: number;
  /** Why the lease dropped to read-only, when status is `readonly`. */
  revokedReason?: LeaseRevokedReason;
  /** Set when a lease request failed to reach the Mac. */
  error?: string;
}

export const idleLease: LeaseSnapshot = { status: 'idle' };

/** Timer seam; defaults to the globals so tests can swap in fake timers. */
export interface LeaseTimers {
  setInterval: (cb: () => void, ms: number) => unknown;
  clearInterval: (handle: unknown) => void;
  setTimeout: (cb: () => void, ms: number) => unknown;
  clearTimeout: (handle: unknown) => void;
}

export interface LeaseControllerDeps {
  /** Send `lease.request` and resolve the correlated grant. */
  requestGrant: (cols: number, rows: number) => Promise<LeaseGrantData>;
  sendHeartbeat: (leaseId: string) => void;
  sendResize: (leaseId: string, cols: number, rows: number) => void;
  sendRelease: (leaseId: string) => void;
  onChange: (snapshot: LeaseSnapshot) => void;
  timers?: Partial<LeaseTimers>;
  /** Resize debounce; default 300ms to match the Mac. */
  resizeDebounceMs?: number;
}

export class LeaseController {
  private readonly deps: LeaseControllerDeps;
  private readonly timers: LeaseTimers;
  private readonly resizeDebounceMs: number;
  private snap: LeaseSnapshot = idleLease;
  private heartbeatHandle: unknown;
  private resizeHandle: unknown;
  /** Bumped on every request/release/reset; a resolving grant checks it to avoid
   * binding a lease the caller has since abandoned. */
  private epoch = 0;

  constructor(deps: LeaseControllerDeps) {
    this.deps = deps;
    this.resizeDebounceMs = deps.resizeDebounceMs ?? 300;
    this.timers = {
      setInterval: deps.timers?.setInterval ?? ((cb, ms) => setInterval(cb, ms)),
      clearInterval: deps.timers?.clearInterval ?? ((h) => clearInterval(h as ReturnType<typeof setInterval>)),
      setTimeout: deps.timers?.setTimeout ?? ((cb, ms) => setTimeout(cb, ms)),
      clearTimeout: deps.timers?.clearTimeout ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>)),
    };
  }

  get snapshot(): LeaseSnapshot {
    return this.snap;
  }

  /** Request a takeover at the phone's measured grid. Idempotent-safe: a second
   * call supersedes the first (the Mac revokes the prior lease as `superseded`). */
  async request(cols: number, rows: number): Promise<void> {
    const epoch = ++this.epoch;
    this.stopHeartbeat();
    this.set({ status: 'requesting', client: { cols, rows }, revokedReason: undefined, error: undefined });
    let grant: LeaseGrantData;
    try {
      grant = await this.deps.requestGrant(cols, rows);
    } catch (error) {
      if (this.epoch !== epoch) {
        return;
      }
      this.set({ status: 'idle', error: error instanceof Error ? error.message : String(error) });
      return;
    }
    if (this.epoch !== epoch) {
      // The caller released/re-requested while the grant was in flight; let the
      // Mac's supersede/expiry path reclaim this orphaned lease.
      return;
    }
    this.set({
      status: 'held',
      leaseId: grant.leaseId,
      effective: grant.effective,
      client: grant.client,
      isCurrentClientLimiting: grant.isCurrentClientLimiting,
      heartbeatIntervalMs: grant.heartbeatIntervalMs,
      revokedReason: undefined,
      error: undefined,
    });
    this.startHeartbeat(grant.leaseId, grant.heartbeatIntervalMs);
  }

  /** Rotation / font change: re-request the grid, debounced. */
  resize(cols: number, rows: number): void {
    if (this.snap.status !== 'held' || this.snap.leaseId === undefined) {
      return;
    }
    const leaseId = this.snap.leaseId;
    if (this.resizeHandle !== undefined) {
      this.timers.clearTimeout(this.resizeHandle);
    }
    this.resizeHandle = this.timers.setTimeout(() => {
      this.resizeHandle = undefined;
      if (this.snap.status !== 'held' || this.snap.leaseId !== leaseId) {
        return;
      }
      this.deps.sendResize(leaseId, cols, rows);
      this.set({ effective: { cols, rows }, client: { cols, rows } });
    }, this.resizeDebounceMs);
  }

  /** Handle an inbound `lease.revoked`: drop to a read-only mirror. */
  handleRevoked(leaseId: string, reason: LeaseRevokedReason): void {
    if (this.snap.leaseId !== leaseId) {
      return;
    }
    this.epoch += 1;
    this.stopHeartbeat();
    this.clearResize();
    this.set({ status: 'readonly', revokedReason: reason });
  }

  /** Phone-initiated release (leaving/backgrounding). No revoked reason follows. */
  release(): void {
    this.epoch += 1;
    this.stopHeartbeat();
    this.clearResize();
    if (this.snap.status === 'held' && this.snap.leaseId !== undefined) {
      this.deps.sendRelease(this.snap.leaseId);
    }
    if (this.snap.status !== 'idle') {
      this.set({ status: 'idle', leaseId: undefined, effective: undefined, revokedReason: undefined });
    }
  }

  /** Full teardown (pane unwatch / connection stop). */
  reset(): void {
    this.epoch += 1;
    this.stopHeartbeat();
    this.clearResize();
    this.snap = idleLease;
  }

  private startHeartbeat(leaseId: string, intervalMs: number): void {
    this.stopHeartbeat();
    this.heartbeatHandle = this.timers.setInterval(() => {
      this.deps.sendHeartbeat(leaseId);
    }, intervalMs);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatHandle !== undefined) {
      this.timers.clearInterval(this.heartbeatHandle);
      this.heartbeatHandle = undefined;
    }
  }

  private clearResize(): void {
    if (this.resizeHandle !== undefined) {
      this.timers.clearTimeout(this.resizeHandle);
      this.resizeHandle = undefined;
    }
  }

  private set(patch: Partial<LeaseSnapshot>): void {
    this.snap = { ...this.snap, ...patch };
    this.deps.onChange(this.snap);
  }
}
