/**
 * Per-pane runtime controller: owns the terminal-text buffer, control lease, and
 * transcript model for one pane, and turns screen intents (watch, input, lease,
 * transcript) into wire messages over the pane's {@link PaneTransport}.
 *
 * Like {@link MacConnection}, the controller lives outside React state; only its
 * plain {@link PaneRuntimeState} snapshot is pushed into the store. The transport
 * seam reads the connection's *current* session on every call, so a reconnect is
 * transparent — {@link PaneController.resync} re-issues the subscriptions and the
 * still-running lease heartbeat rebinds to the new session automatically.
 */

import type { ParsedMessage, TranscriptEntry } from '@zentty/wire';

import type { InputKey } from '@zentty/wire';

import { coalescePaneText, withScrollback, type PaneTextFrame, type PaneTextState } from './paneText';
import { PaneBytesLane, type PaneBytesChunkFrame, type PaneBytesEffects } from './paneBytesLane';
import {
  LeaseController,
  idleLease,
  type LeaseGrantData,
  type LeaseSnapshot,
} from './leaseController';
import {
  applyTranscriptDelta,
  applyTranscriptSnapshot,
  applyTranscriptUnavailable,
  initialTranscript,
  loadingTranscript,
  type TranscriptState,
} from './transcript';

/** Session access the controller needs; implemented by {@link MacConnection}. */
export interface PaneTransport {
  /** Fire-and-forget send (dropped when no session is ready). */
  send(type: string, payload: unknown): void;
  /** Request/response correlated by `replyTo`; rejects when not ready. */
  request(type: string, payload: unknown): Promise<ParsedMessage>;
  isReady(): boolean;
}

/** Serializable per-pane state the store holds and the screen renders. */
export interface PaneRuntimeState {
  watching: boolean;
  text?: PaneTextState;
  scrollbackLoading: boolean;
  /** Set when the last `pane.scrollback` request failed or timed out; cleared by
   * the next successful fetch or by re-{@link PaneController.watch}ing the pane. */
  scrollbackError: boolean;
  lease: LeaseSnapshot;
  transcript: TranscriptState;
}

export function initialPaneRuntime(): PaneRuntimeState {
  return {
    watching: false,
    scrollbackLoading: false,
    scrollbackError: false,
    lease: idleLease,
    transcript: initialTranscript,
  };
}

export class PaneController {
  private readonly paneId: string;
  private readonly transport: PaneTransport;
  private readonly onChange: (state: PaneRuntimeState) => void;
  private readonly lease: LeaseController;
  state: PaneRuntimeState = initialPaneRuntime();
  private subscribedTranscript = false;
  /** Raw-PTY byte lane, created lazily when the screen opts into the xterm path
   * via {@link attachBytes}. Null while on (or fallen back to) the text path. */
  private bytesLane: PaneBytesLane | null = null;
  /** Implicit-control intent: true while the pane screen is focused+foregrounded.
   * Gates auto-acquire (and re-acquire on reconnect); cleared on leave/background. */
  private controlWanted = false;
  /** Latest measured phone grid; the viewport a lease is requested/resized at. */
  private viewport?: { cols: number; rows: number };

  constructor(
    paneId: string,
    transport: PaneTransport,
    onChange: (state: PaneRuntimeState) => void,
  ) {
    this.paneId = paneId;
    this.transport = transport;
    this.onChange = onChange;
    this.lease = new LeaseController({
      requestGrant: (cols, rows) => this.requestGrant(cols, rows),
      // The controller gates the send on isReady; when down long enough it
      // degrades the lease to read-only.
      isReady: () => this.transport.isReady(),
      sendHeartbeat: (leaseId) => this.transport.send('lease.heartbeat', { leaseId }),
      sendResize: (leaseId, cols, rows) => this.transport.send('lease.resize', { leaseId, cols, rows }),
      sendRelease: (leaseId) => this.transport.send('lease.release', { leaseId }),
      onChange: (snapshot) => this.emit({ lease: snapshot }),
    });
  }

  // MARK: - Terminal text

  /** Begin mirroring the pane. Re-issued on reconnect via {@link resync}. */
  watch(): void {
    this.emit({ watching: true, scrollbackError: false });
    if (this.transport.isReady()) {
      this.transport.send('pane.watch', { paneId: this.paneId });
    }
  }

  /** Stop mirroring and release any lease this pane holds. */
  unwatch(): void {
    if (this.state.watching && this.transport.isReady()) {
      this.transport.send('pane.unwatch', { paneId: this.paneId });
    }
    this.controlWanted = false;
    this.lease.release();
    this.subscribedTranscript = false;
    this.detachBytes();
    this.emit({ watching: false });
  }

  onPaneText(payload: PaneTextFrame): void {
    const next = coalescePaneText(this.state.text, payload);
    if (next === null) {
      return; // stale seq — drop.
    }
    this.emit({ text: next });
  }

  async fetchScrollback(lineLimit = 2000): Promise<void> {
    if (!this.transport.isReady() || this.state.scrollbackLoading) {
      return;
    }
    this.emit({ scrollbackLoading: true });
    try {
      const reply = await this.transport.request('pane.scrollback', { paneId: this.paneId, lineLimit });
      const text = (reply.payload as { text?: string }).text ?? '';
      this.emit({ text: withScrollback(this.state.text, text), scrollbackError: false });
    } catch (error) {
      // Leave the current buffer in place, but surface the failure — a pull-to-top
      // that silently does nothing (e.g. a RequestTimeoutError) reads as broken.
      console.warn(`[PaneController] pane.scrollback failed for pane ${this.paneId}`, error);
      this.emit({ scrollbackError: true });
    } finally {
      this.emit({ scrollbackLoading: false });
    }
  }

  // MARK: - Raw-PTY byte lane (xterm path)

  /**
   * Opt this pane into the streaming byte lane. The screen passes emulator sinks
   * (write/reset) plus an `onUnsupported` callback; the lane cold-attaches and, if
   * the mac can't speak `pane.bytes.*`, fires `onUnsupported` so the screen falls
   * back to the plain-text {@link TerminalView} path.
   *
   * Idempotent: a second call rebinds sinks (e.g. WebView remounted) and
   * warm-resyncs when a live lane already exists. Replacing effects never orphans
   * a prior lane without a detach.
   */
  attachBytes(effects: PaneBytesEffects): void {
    const wrapped: PaneBytesEffects = {
      // Spread first so any effect this wrapper does not deliberately intercept
      // is forwarded. Listing hooks by hand silently dropped `onGrid` (optional
      // on the interface, so the compiler said nothing), which made the whole
      // mac-authoritative geometry policy dead code in the shipped path.
      ...effects,
      onWrite: (data) => effects.onWrite(data),
      onReset: () => effects.onReset(),
      onUnsupported: () => {
        // Permanent fallback: stop streaming and drop the lane so reconnect
        // resync does not keep probing a dead protocol path.
        this.bytesLane?.detach();
        this.bytesLane = null;
        effects.onUnsupported();
      },
    };

    if (this.bytesLane && !this.bytesLane.isDead) {
      this.bytesLane.setEffects(wrapped);
      void this.bytesLane.resync();
      return;
    }

    this.bytesLane?.detach();
    this.bytesLane = new PaneBytesLane(this.paneId, this.transport, wrapped);
    void this.bytesLane.attach();
  }

  /** Route a live `pane.bytes.chunk` to the lane (no-op on the text path). */
  onPaneBytesChunk(frame: PaneBytesChunkFrame): void {
    void this.bytesLane?.onChunk(frame);
  }

  /** Leave the byte lane (tell the mac to stop streaming) and drop it. */
  detachBytes(): void {
    this.bytesLane?.detach();
    this.bytesLane = null;
  }

  /** Warm- or cold-resume the byte lane without rebinding sinks. */
  resyncBytes(): void {
    void this.bytesLane?.resync();
  }

  // MARK: - Input

  sendText(text: string): void {
    this.transport.send('input.text', { paneId: this.paneId, text });
  }

  sendKey(key: InputKey): void {
    this.transport.send('input.key', { paneId: this.paneId, key });
  }

  quickAction(actionId: string): void {
    this.transport.send('input.quickAction', { paneId: this.paneId, actionId });
  }

  // MARK: - Lease (implicit control)

  /**
   * Screen entered (focus) or returned to the foreground: express intent to
   * control this pane. The actual `lease.request` fires from {@link maybeAcquire}
   * once a viewport is known and the transport is ready — so it is safe to call
   * before the grid is measured or while offline (it re-acquires on reconnect).
   */
  acquireControl(): void {
    this.controlWanted = true;
    this.maybeAcquire();
  }

  /** Screen left (blur/unmount) or backgrounded: drop intent and release. */
  releaseControl(): void {
    this.controlWanted = false;
    this.lease.release();
  }

  /**
   * User tapped the "view only" indicator to retry after a denied or lost lease.
   * A denied lease sits at idle+error and a lost one at readonly — neither of
   * which {@link maybeAcquire} re-fires — so force a fresh request.
   */
  retryControl(): void {
    this.controlWanted = true;
    if (this.viewport && this.transport.isReady()) {
      void this.lease.request(this.viewport.cols, this.viewport.rows);
    }
  }

  /**
   * Feed the measured phone grid. Acquires control when it is wanted and no lease
   * is held yet; while a lease is held, resizes (debounced) — but only on a column
   * change, so toggling the keyboard (a height-only delta) doesn't spam SIGWINCH.
   */
  setViewport(cols: number, rows: number): void {
    this.viewport = { cols, rows };
    const lease = this.state.lease;
    if (lease.status === 'held') {
      if (lease.effective?.cols !== cols) {
        this.lease.resize(cols, rows);
      }
      return;
    }
    this.maybeAcquire();
  }

  handleLeaseRevoked(leaseId: string, reason: Parameters<LeaseController['handleRevoked']>[1]): void {
    this.lease.handleRevoked(leaseId, reason);
  }

  /** Request a lease iff control is wanted, a viewport is known, the transport is
   * ready, and no lease is pending/held. A denied lease (idle+error) is left alone
   * so a refusal doesn't spin into a request loop; the user retries explicitly. */
  private maybeAcquire(): void {
    if (!this.controlWanted || !this.viewport || !this.transport.isReady()) {
      return;
    }
    const lease = this.state.lease;
    if (lease.status === 'idle' && lease.error === undefined) {
      void this.lease.request(this.viewport.cols, this.viewport.rows);
    }
  }

  private async requestGrant(cols: number, rows: number): Promise<LeaseGrantData> {
    const reply = await this.transport.request('lease.request', { paneId: this.paneId, cols, rows });
    if (reply.type !== 'lease.grant') {
      throw new Error(`unexpected lease reply: ${reply.type}`);
    }
    return reply.payload as LeaseGrantData;
  }

  // MARK: - Transcript

  async subscribeTranscript(): Promise<void> {
    this.subscribedTranscript = true;
    if (!this.transport.isReady()) {
      this.emit({ transcript: loadingTranscript(this.state.transcript) });
      return;
    }
    this.emit({ transcript: loadingTranscript(this.state.transcript) });
    try {
      const reply = await this.transport.request('transcript.subscribe', { paneId: this.paneId });
      if (reply.type === 'transcript.snapshot') {
        this.emit({ transcript: applyTranscriptSnapshot(reply.payload as never) });
      } else if (reply.type === 'transcript.unavailable') {
        this.emit({
          transcript: applyTranscriptUnavailable(
            this.state.transcript,
            (reply.payload as { reason: never }).reason,
          ),
        });
      }
    } catch {
      // A dropped session resolves via resync on reconnect; keep the loading state.
    }
  }

  onTranscriptDelta(payload: { entries: TranscriptEntry[] }): void {
    this.emit({ transcript: applyTranscriptDelta(this.state.transcript, payload) });
  }

  onTranscriptUnavailable(reason: Parameters<typeof applyTranscriptUnavailable>[1]): void {
    this.emit({ transcript: applyTranscriptUnavailable(this.state.transcript, reason) });
  }

  // MARK: - Reconnect

  /** Re-issue subscriptions after a session comes back, and re-validate any held
   * lease. If the gap outlived the Mac's lease expiry the Mac already revoked it;
   * {@link LeaseController.reconcile} re-requests a fresh grant (or degrades to a
   * read-only mirror) rather than trusting a possibly-dead `held` state. */
  resync(): void {
    if (this.state.watching) {
      this.transport.send('pane.watch', { paneId: this.paneId });
    }
    if (this.subscribedTranscript) {
      void this.subscribeTranscript();
    }
    // Warm-resume the byte lane from the last contiguous offset (or cold attach if
    // it never established one) so the emulator survives a reconnect.
    void this.bytesLane?.resync();
    // A held lease renews in place; a lease we wanted but never got (entered while
    // offline, or backgrounded and reconnected) is acquired fresh now that the
    // session is back. Both are gated so at most one path fires.
    void this.lease.reconcile();
    this.maybeAcquire();
  }

  /** Permanent teardown (connection stopped). */
  dispose(): void {
    this.detachBytes();
    this.lease.reset();
  }

  private emit(patch: Partial<PaneRuntimeState>): void {
    this.state = { ...this.state, ...patch };
    this.onChange(this.state);
  }
}
