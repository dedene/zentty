/**
 * Phone-side state machine for the raw-PTY byte lane (`pane.bytes.*`).
 *
 * Where {@link ./paneText} folds debounced viewport *snapshots*, this lane drives
 * a real VT emulator (xterm.js, running inside a WebView) from the mac's verbatim
 * PTY output. The controller here owns only the *protocol* — attach/resume/gap/
 * epoch sequencing — and emits two side effects the view layer applies to the
 * emulator: {@link PaneBytesEffects.onWrite} (feed base64 bytes) and
 * {@link PaneBytesEffects.onReset} (discard emulator state). It never touches the
 * DOM, so it is unit-testable in Node.
 *
 * Sequencing (see companion/wire/src/families/paneBytes.ts):
 * - `epoch` is an opaque per-surface-lifetime id. A frame carrying an epoch we
 *   don't recognize means the surface restarted → reset + cold attach.
 * - `seq`/`startSeq` are BYTE OFFSETS within an epoch. The next expected offset is
 *   `seq + decodedByteLength(data)`. A chunk whose `seq` != our expected offset is
 *   a gap → warm re-attach carrying `lastSeq` as the exclusive resume cursor
 *   (the first missing byte offset).
 * - `snapshot` (cold attach / post-gap resync) is a self-contained VT stream that
 *   reproduces the mac's screen. It is applied as reset → grid → write, and is
 *   EXCLUDED from seq arithmetic: the next expected offset stays
 *   `startSeq + decodedByteLength(replay)`.
 *
 * Version gating: a mac too old to speak this lane answers with a wrong type
 * (e.g. `session.error` / `unsupported_type`); {@link PaneBytesEffects.onUnsupported}
 * fires so the screen can fall back to the plain-text `pane.*` lane. Transient
 * transport failures (timeout, session close) do NOT sticky-fallback — a later
 * {@link PaneBytesLane.resync} retries.
 */

import type { PaneBytesAttached, PaneBytesChunk } from '@zentty/wire';

import { RequestTimeoutError, SessionClosedError } from '../core/session';
import type { PaneTransport } from './paneController';

/** Decoded `pane.bytes.attached` payload. */
export type PaneBytesAttachedPayload = ReturnType<typeof PaneBytesAttached.parse>;
/** Decoded `pane.bytes.chunk` payload. */
export type PaneBytesChunkFrame = ReturnType<typeof PaneBytesChunk.parse>;

/** Side effects the lane emits; the view layer applies them to the emulator. */
export interface PaneBytesEffects {
  /** Feed a run of standard-base64 bytes to the emulator (in arrival order). */
  onWrite(dataB64: string): void;
  /** Discard all emulator state before the next write (fresh baseline). */
  onReset(): void;
  /** The mac can't speak this lane — fall back to the plain-text path. */
  onUnsupported(): void;
  /**
   * The mac's authoritative grid at snapshot-capture time. Emitted between
   * {@link onReset} and the snapshot {@link onWrite} so the emulator is already
   * the right size when the snapshot's cursor/scroll-region bytes land. The view
   * layer sizes the emulator to this grid and letterboxes it while mirroring
   * read-only; it only fits to the phone's own grid while a control lease is
   * held (then the mac follows and re-snapshots). Optional so callers that do
   * not render geometry (tests, headless consumers) need not implement it.
   */
  onGrid?(cols: number, rows: number): void;
}

/**
 * Decoded byte length of a standard-base64 string, WITHOUT decoding it. Mirrors
 * the mac's "advance by decoded byte length" rule so byte offsets stay in lock-
 * step. Tolerates both padded (`QQ==`) and unpadded (`QQ`) spellings — the wire
 * schema permits `={0,2}` padding — by recovering length from the character count.
 */
export function decodedBase64Length(b64: string): number {
  let end = b64.length;
  while (end > 0 && b64.charCodeAt(end - 1) === 0x3d /* '=' */) {
    end -= 1;
  }
  const chars = end;
  const fullGroups = Math.floor(chars / 4);
  const rem = chars - fullGroups * 4;
  let bytes = fullGroups * 3;
  if (rem === 2) {
    bytes += 1;
  } else if (rem === 3) {
    bytes += 2;
  }
  // rem === 1 is not a valid base64 tail; treat as zero extra bytes.
  return bytes;
}

/** True when an attach failure should *not* sticky-fallback to the text path. */
export function isTransientAttachFailure(err: unknown): boolean {
  if (err instanceof RequestTimeoutError || err instanceof SessionClosedError) {
    return true;
  }
  if (err instanceof Error) {
    const msg = err.message.toLowerCase();
    if (msg.includes('session not ready') || msg.includes('not ready')) {
      return true;
    }
  }
  return false;
}

type AttachPayload = {
  paneId: string;
  lastSeq?: number;
  epoch?: string;
};

type PendingFollowup = { kind: 'cold' } | { kind: 'warm'; lastSeq: number; epoch: string };

export class PaneBytesLane {
  private readonly paneId: string;
  private readonly transport: PaneTransport;
  private effects: PaneBytesEffects;

  /** Current surface epoch, or undefined before the first successful attach. */
  private epoch: string | undefined;
  /** Next expected byte offset within {@link epoch} (exclusive end of held range). */
  private expected = 0;
  /** True while an attach request is in flight; incoming chunks are deferred. */
  private attaching = false;
  /**
   * Generation counter: bumped on every detach and at the start of each attach.
   * After `await request`, a mismatched gen means this lane was detached (or a
   * newer attach superseded us) — ignore the reply and do not touch effects.
   */
  private attachGeneration = 0;
  /** When a gap/resync arrives mid-attach, run another attach after the current one. */
  private pendingFollowup: PendingFollowup | null = null;
  /** Soft-closed after permanent unsupported so late chunks/resyncs no-op. */
  private dead = false;

  constructor(paneId: string, transport: PaneTransport, effects: PaneBytesEffects) {
    this.paneId = paneId;
    this.transport = transport;
    this.effects = effects;
  }

  /** Rebind emulator sinks (e.g. WebView remounted) without tearing down the lane. */
  setEffects(effects: PaneBytesEffects): void {
    this.effects = effects;
  }

  /** True after permanent unsupported — controller should drop this lane. */
  get isDead(): boolean {
    return this.dead;
  }

  /** Last exclusive resume cursor (next missing byte offset). */
  get expectedOffset(): number {
    return this.expected;
  }

  /** Current surface epoch, or undefined before the first attach. */
  get currentEpoch(): string | undefined {
    return this.epoch;
  }

  /** Cold attach: replay the mac's tail and stream forward from it. */
  attach(): Promise<void> {
    return this.runAttach({ paneId: this.paneId });
  }

  /**
   * Re-establish the lane after a reconnect. If we still hold an epoch, warm-
   * resume from the exclusive next offset (the mac replays forward, or resets us
   * via `truncated` if the ring rolled past it); otherwise cold attach.
   */
  resync(): Promise<void> {
    if (this.dead) {
      return Promise.resolve();
    }
    if (this.attaching) {
      this.pendingFollowup =
        this.epoch !== undefined
          ? { kind: 'warm', lastSeq: this.expected, epoch: this.epoch }
          : { kind: 'cold' };
      return Promise.resolve();
    }
    if (this.epoch !== undefined) {
      return this.runAttach({ paneId: this.paneId, lastSeq: this.expected, epoch: this.epoch });
    }
    return this.attach();
  }

  /** Route one live `pane.bytes.chunk`. Returns a promise only when the frame
   * triggers a re-attach (so tests can await recovery). */
  onChunk(frame: PaneBytesChunkFrame): Promise<void> | void {
    if (this.dead || frame.paneId !== this.paneId) {
      return;
    }
    if (this.attaching) {
      // Defer recovery until the in-flight attach settles — do not drop the need.
      if (this.epoch === undefined || frame.epoch !== this.epoch) {
        this.pendingFollowup = { kind: 'cold' };
      } else if (frame.seq > this.expected) {
        this.pendingFollowup = { kind: 'warm', lastSeq: this.expected, epoch: this.epoch };
      }
      // Contiguous/duplicate chunks while attaching: the attached reply is
      // authoritative; no follow-up needed.
      return;
    }
    if (this.epoch === undefined) {
      return; // no baseline yet; the controller drives attach()
    }
    if (frame.epoch !== this.epoch) {
      return this.runAttach({ paneId: this.paneId });
    }
    if (frame.seq < this.expected) {
      return; // duplicate / already-applied bytes
    }
    if (frame.seq > this.expected) {
      return this.runAttach({ paneId: this.paneId, lastSeq: this.expected, epoch: this.epoch });
    }
    // Contiguous: apply and advance.
    this.effects.onWrite(frame.data);
    this.expected += decodedBase64Length(frame.data);
  }

  /** Leaving the pane: stop the mac's stream and clear local state. */
  detach(): void {
    this.attachGeneration += 1;
    this.pendingFollowup = null;
    // Always notify the Mac when ready — even after permanent unsupported
    // (markUnsupported sets dead before the controller's detach wrapper runs).
    if (this.transport.isReady()) {
      this.transport.send('pane.bytes.detach', { paneId: this.paneId });
    }
    this.epoch = undefined;
    this.expected = 0;
    this.attaching = false;
  }

  private markUnsupported(): void {
    this.dead = true;
    this.pendingFollowup = null;
    this.epoch = undefined;
    this.expected = 0;
    // Controller wraps onUnsupported to call detachBytes() (sends detach once).
    this.effects.onUnsupported();
  }

  private async runAttach(payload: AttachPayload): Promise<void> {
    if (this.dead) {
      return;
    }
    if (this.attaching) {
      // Coalesce: prefer cold over warm when both are requested mid-flight.
      if (payload.lastSeq === undefined || payload.epoch === undefined) {
        this.pendingFollowup = { kind: 'cold' };
      } else if (this.pendingFollowup?.kind !== 'cold') {
        this.pendingFollowup = { kind: 'warm', lastSeq: payload.lastSeq, epoch: payload.epoch };
      }
      return;
    }
    if (!this.transport.isReady()) {
      return; // resync() re-fires once the session is back
    }

    this.attaching = true;
    const gen = ++this.attachGeneration;
    try {
      const reply = await this.transport.request('pane.bytes.attach', payload);
      if (gen !== this.attachGeneration || this.dead) {
        return; // detached or superseded while in flight
      }
      if (reply.type !== 'pane.bytes.attached') {
        // Old mac / protocol rejection (incl. session.error unsupported_type).
        this.markUnsupported();
        return;
      }
      const p = reply.payload as PaneBytesAttachedPayload;
      if (p.paneId !== this.paneId) {
        // Misrouted reply — do not apply; try a cold re-attach next tick.
        this.pendingFollowup = { kind: 'cold' };
        return;
      }
      // A snapshot IS the resync: reset unconditionally (so one arriving mid-
      // session repaints instead of stacking on the stale screen), size to the
      // mac's grid, then write it. `truncated` is advisory in that case.
      if (p.snapshot !== undefined) {
        this.effects.onReset();
        if (p.snapshotCols !== undefined && p.snapshotRows !== undefined) {
          this.effects.onGrid?.(p.snapshotCols, p.snapshotRows);
        }
        if (p.snapshot.length > 0) {
          this.effects.onWrite(p.snapshot);
        }
      } else if (p.truncated || (this.epoch !== undefined && p.epoch !== this.epoch)) {
        this.effects.onReset();
      }
      this.epoch = p.epoch;
      this.expected = p.startSeq + decodedBase64Length(p.replay);
      if (p.replay.length > 0) {
        this.effects.onWrite(p.replay);
      }
    } catch (err) {
      if (gen !== this.attachGeneration || this.dead) {
        return;
      }
      if (isTransientAttachFailure(err)) {
        // Leave epoch/expected alone so a later resync can warm-resume.
        return;
      }
      // Unexpected throw (e.g. explicit protocol rejection without typed error).
      this.markUnsupported();
    } finally {
      if (gen === this.attachGeneration) {
        this.attaching = false;
        const follow = this.pendingFollowup;
        this.pendingFollowup = null;
        if (!this.dead && follow) {
          if (follow.kind === 'cold') {
            void this.runAttach({ paneId: this.paneId });
          } else {
            void this.runAttach({
              paneId: this.paneId,
              lastSeq: follow.lastSeq,
              epoch: follow.epoch,
            });
          }
        }
      }
    }
  }
}
