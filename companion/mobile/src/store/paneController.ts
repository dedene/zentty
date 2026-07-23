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
  lease: LeaseSnapshot;
  transcript: TranscriptState;
}

export function initialPaneRuntime(): PaneRuntimeState {
  return {
    watching: false,
    scrollbackLoading: false,
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
      sendHeartbeat: (leaseId) => {
        if (this.transport.isReady()) {
          this.transport.send('lease.heartbeat', { leaseId });
        }
      },
      sendResize: (leaseId, cols, rows) => this.transport.send('lease.resize', { leaseId, cols, rows }),
      sendRelease: (leaseId) => this.transport.send('lease.release', { leaseId }),
      onChange: (snapshot) => this.emit({ lease: snapshot }),
    });
  }

  // MARK: - Terminal text

  /** Begin mirroring the pane. Re-issued on reconnect via {@link resync}. */
  watch(): void {
    this.emit({ watching: true });
    if (this.transport.isReady()) {
      this.transport.send('pane.watch', { paneId: this.paneId });
    }
  }

  /** Stop mirroring and release any lease this pane holds. */
  unwatch(): void {
    if (this.state.watching && this.transport.isReady()) {
      this.transport.send('pane.unwatch', { paneId: this.paneId });
    }
    this.lease.release();
    this.subscribedTranscript = false;
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
      this.emit({ text: withScrollback(this.state.text, text) });
    } catch {
      // Best-effort: leave the current buffer in place.
    } finally {
      this.emit({ scrollbackLoading: false });
    }
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

  // MARK: - Lease

  requestLease(cols: number, rows: number): void {
    void this.lease.request(cols, rows);
  }

  resizeLease(cols: number, rows: number): void {
    this.lease.resize(cols, rows);
  }

  releaseLease(): void {
    this.lease.release();
  }

  handleLeaseRevoked(leaseId: string, reason: Parameters<LeaseController['handleRevoked']>[1]): void {
    this.lease.handleRevoked(leaseId, reason);
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

  /** Re-issue subscriptions after a session comes back. The lease heartbeat keeps
   * running across the gap, so heartbeating the same `leaseId` rebinds it. */
  resync(): void {
    if (this.state.watching) {
      this.transport.send('pane.watch', { paneId: this.paneId });
    }
    if (this.subscribedTranscript) {
      void this.subscribeTranscript();
    }
  }

  /** Permanent teardown (connection stopped). */
  dispose(): void {
    this.lease.reset();
  }

  private emit(patch: Partial<PaneRuntimeState>): void {
    this.state = { ...this.state, ...patch };
    this.onChange(this.state);
  }
}
