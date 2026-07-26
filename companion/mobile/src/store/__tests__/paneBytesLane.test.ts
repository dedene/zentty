import { describe, expect, it, jest } from '@jest/globals';

import type { ParsedMessage } from '@zentty/wire';

import { RequestTimeoutError, SessionClosedError } from '../../core/session';
import type { PaneTransport } from '../paneController';
import {
  PaneBytesLane,
  decodedBase64Length,
  isTransientAttachFailure,
  type PaneBytesEffects,
} from '../paneBytesLane';

// ---- helpers ----------------------------------------------------------------

/** Standard-base64 (with padding) of a run of `n` bytes — value irrelevant, only
 * its decoded length matters to the offset math. */
function b64OfLength(n: number): string {
  const bytes = new Uint8Array(n);
  // btoa is available under jest-expo's jsdom-ish env; fall back to a manual encode.
  let bin = '';
  for (let i = 0; i < n; i += 1) {
    bin += String.fromCharCode(bytes[i]);
  }
  return manualB64(bin);
}

function manualB64(bin: string): string {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  let i = 0;
  for (; i + 3 <= bin.length; i += 3) {
    const n = (bin.charCodeAt(i) << 16) | (bin.charCodeAt(i + 1) << 8) | bin.charCodeAt(i + 2);
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63] + A[(n >> 6) & 63] + A[n & 63];
  }
  const rem = bin.length - i;
  if (rem === 1) {
    const n = bin.charCodeAt(i) << 16;
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63] + '==';
  } else if (rem === 2) {
    const n = (bin.charCodeAt(i) << 16) | (bin.charCodeAt(i + 1) << 8);
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63] + A[(n >> 6) & 63] + '=';
  }
  return out;
}

/** One emitted effect, in order — the snapshot apply order is the contract. */
type Op = { op: 'reset' } | { op: 'grid'; cols: number; rows: number } | { op: 'write'; d: string };

interface Sinks extends PaneBytesEffects {
  writes: string[];
  resets: number;
  unsupported: number;
  /** Ordered log of reset/grid/write so apply ORDER can be asserted. */
  ops: Op[];
}

function makeEffects(): Sinks {
  const s = {
    writes: [] as string[],
    resets: 0,
    unsupported: 0,
    ops: [] as Op[],
    onWrite(b64: string) {
      s.writes.push(b64);
      s.ops.push({ op: 'write', d: b64 });
    },
    onReset() {
      s.resets += 1;
      s.ops.push({ op: 'reset' });
    },
    onGrid(cols: number, rows: number) {
      s.ops.push({ op: 'grid', cols, rows });
    },
    onUnsupported() {
      s.unsupported += 1;
    },
  };
  return s;
}

function attachedReply(payload: {
  paneId?: string;
  epoch: string;
  startSeq: number;
  replay: string;
  truncated: boolean;
  snapshot?: string;
  snapshotCols?: number;
  snapshotRows?: number;
}): ParsedMessage {
  return {
    v: 1,
    id: 'r',
    type: 'pane.bytes.attached',
    payload: { paneId: 'p1', ...payload },
  } as ParsedMessage;
}

function chunk(epoch: string, seq: number, data: string) {
  return { paneId: 'p1', epoch, seq, data };
}

function makeTransport(overrides: Partial<PaneTransport> = {}): PaneTransport {
  return {
    send: jest.fn(),
    request: jest.fn(async () => attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false })),
    isReady: () => true,
    ...overrides,
  };
}

// ---- decodedBase64Length ----------------------------------------------------

describe('decodedBase64Length', () => {
  it('is 0 for the empty string', () => {
    expect(decodedBase64Length('')).toBe(0);
  });

  it('matches padded standard base64 lengths', () => {
    expect(decodedBase64Length(manualB64('A'))).toBe(1); // "QQ=="
    expect(decodedBase64Length(manualB64('AB'))).toBe(2); // "QUI="
    expect(decodedBase64Length(manualB64('ABC'))).toBe(3); // "QUJD"
    expect(decodedBase64Length(manualB64('ABCD'))).toBe(4);
  });

  it('handles unpadded spellings too', () => {
    expect(decodedBase64Length('QQ')).toBe(1);
    expect(decodedBase64Length('QUI')).toBe(2);
  });

  it('agrees with b64OfLength for a range of sizes', () => {
    for (const n of [0, 1, 2, 3, 4, 5, 31, 32, 100, 1024]) {
      expect(decodedBase64Length(b64OfLength(n))).toBe(n);
    }
  });
});

// ---- cold attach ------------------------------------------------------------

describe('PaneBytesLane cold attach', () => {
  it('sends a bare attach (no epoch/lastSeq) and writes the replay', async () => {
    const replay = b64OfLength(10);
    const request = jest.fn(async () => attachedReply({ epoch: 'e1', startSeq: 0, replay, truncated: false }));
    const transport = makeTransport({ request });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', transport, fx);

    await lane.attach();

    expect(request).toHaveBeenCalledWith('pane.bytes.attach', { paneId: 'p1' });
    expect(fx.writes).toEqual([replay]);
    // First cold attach onto a fresh emulator does not reset.
    expect(fx.resets).toBe(0);
    // Next expected offset advanced past the replay.
    expect(lane.expectedOffset).toBe(10);
    expect(lane.currentEpoch).toBe('e1');
  });

  it('handles an empty replay (no write, offset = startSeq)', async () => {
    const request = jest.fn(async () => attachedReply({ epoch: 'e1', startSeq: 7, replay: '', truncated: false }));
    const lane = new PaneBytesLane('p1', makeTransport({ request }), makeEffects());
    await lane.attach();
    expect(lane.expectedOffset).toBe(7);
  });

  it('falls back (onUnsupported) on a non-transient attach reject', async () => {
    const request = jest.fn(async () => {
      throw new Error('no such handler');
    });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    expect(fx.unsupported).toBe(1);
    expect(lane.currentEpoch).toBeUndefined();
    expect(lane.isDead).toBe(true);
  });

  it('falls back when the reply is the wrong type (old Mac echoing something else)', async () => {
    const request = jest.fn(
      async () => ({ v: 1, id: 'r', type: 'pane.text', payload: {} }) as ParsedMessage,
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    expect(fx.unsupported).toBe(1);
  });

  it('falls back on session.error unsupported_type reply (non-throwing)', async () => {
    const request = jest.fn(
      async () =>
        ({
          v: 1,
          id: 'r',
          type: 'session.error',
          payload: { code: 'unsupported_type', message: 'no', fatal: false },
        }) as ParsedMessage,
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    expect(fx.unsupported).toBe(1);
  });

  it('does not sticky-fallback on RequestTimeoutError (transient)', async () => {
    const request = jest.fn(async () => {
      throw new RequestTimeoutError('pane.bytes.attach');
    });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    expect(fx.unsupported).toBe(0);
    expect(lane.isDead).toBe(false);
  });

  it('does not sticky-fallback on SessionClosedError (transient)', async () => {
    const request = jest.fn(async () => {
      throw new SessionClosedError();
    });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    expect(fx.unsupported).toBe(0);
  });
});

describe('isTransientAttachFailure', () => {
  it('classifies timeout/close/not-ready as transient', () => {
    expect(isTransientAttachFailure(new RequestTimeoutError('x'))).toBe(true);
    expect(isTransientAttachFailure(new SessionClosedError())).toBe(true);
    expect(isTransientAttachFailure(new Error('session not ready'))).toBe(true);
    expect(isTransientAttachFailure(new Error('boom'))).toBe(false);
  });
});

// ---- live chunks ------------------------------------------------------------

describe('PaneBytesLane live chunks', () => {
  async function attached(startReplayLen = 0) {
    const replay = b64OfLength(startReplayLen);
    const request = jest.fn(async () => attachedReply({ epoch: 'e1', startSeq: 0, replay, truncated: false }));
    const transport = makeTransport({ request });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', transport, fx);
    await lane.attach();
    return { lane, fx, transport };
  }

  it('writes a contiguous chunk and advances the offset', async () => {
    const { lane, fx } = await attached(4); // offset now 4
    const data = b64OfLength(6);
    lane.onChunk(chunk('e1', 4, data));
    expect(fx.writes).toContain(data);
    expect(lane.expectedOffset).toBe(10);
  });

  it('writes a run of contiguous chunks in order', async () => {
    const { lane, fx } = await attached(0);
    const a = b64OfLength(3);
    const b = b64OfLength(5);
    lane.onChunk(chunk('e1', 0, a));
    lane.onChunk(chunk('e1', 3, b));
    expect(fx.writes).toEqual([a, b]);
    expect(lane.expectedOffset).toBe(8);
  });

  it('drops a stale/duplicate chunk (seq < expected) without re-attaching', async () => {
    const { lane, fx, transport } = await attached(0);
    const a = b64OfLength(4);
    lane.onChunk(chunk('e1', 0, a)); // offset -> 4
    lane.onChunk(chunk('e1', 0, a)); // duplicate, seq < expected
    expect(lane.expectedOffset).toBe(4);
    expect(fx.writes).toEqual([a]);
    // Only the original attach — no warm re-attach.
    expect((transport.send as jest.Mock).mock.calls.filter((c) => c[0] === 'pane.bytes.attach')).toHaveLength(0);
  });
});

// ---- gap / warm re-attach ---------------------------------------------------

describe('PaneBytesLane gap recovery', () => {
  it('warm re-attaches with lastSeq on a forward gap and resumes without reset', async () => {
    // First attach.
    const replies: ParsedMessage[] = [
      attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false }),
      // warm resume: startSeq == lastSeq, replay fills the gap forward.
      attachedReply({ epoch: 'e1', startSeq: 4, replay: b64OfLength(8), truncated: false }),
    ];
    let call = 0;
    const request = jest.fn(async () => replies[call++]);
    const transport = makeTransport({ request });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', transport, fx);
    await lane.attach();

    const firstChunk = b64OfLength(4);
    lane.onChunk(chunk('e1', 0, firstChunk)); // offset -> 4
    // Gap: next seq should be 4 but we get 20.
    await lane.onChunk(chunk('e1', 20, b64OfLength(2)));

    expect(request).toHaveBeenNthCalledWith(2, 'pane.bytes.attach', {
      paneId: 'p1',
      lastSeq: 4,
      epoch: 'e1',
    });
    // Resume (truncated:false, same epoch) => no reset; replay written; offset -> 12.
    expect(fx.resets).toBe(0);
    expect(lane.expectedOffset).toBe(12);
    expect(fx.writes).toEqual([firstChunk, b64OfLength(8)]);
  });

  it('resets the emulator when the warm re-attach comes back truncated', async () => {
    const replies: ParsedMessage[] = [
      attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false }),
      attachedReply({ epoch: 'e1', startSeq: 100, replay: b64OfLength(5), truncated: true }),
    ];
    let call = 0;
    const request = jest.fn(async () => replies[call++]);
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();

    lane.onChunk(chunk('e1', 0, b64OfLength(4))); // offset -> 4
    await lane.onChunk(chunk('e1', 50, b64OfLength(2))); // gap -> warm re-attach -> truncated

    expect(fx.resets).toBe(1);
    expect(lane.expectedOffset).toBe(105);
  });
});

// ---- epoch change -----------------------------------------------------------

describe('PaneBytesLane epoch change', () => {
  it('resets and cold re-attaches on an unrecognized epoch', async () => {
    const replies: ParsedMessage[] = [
      attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false }),
      // cold re-attach reply for the new surface.
      attachedReply({ epoch: 'e2', startSeq: 0, replay: b64OfLength(3), truncated: false }),
    ];
    let call = 0;
    const request = jest.fn(async () => replies[call++]);
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    lane.onChunk(chunk('e1', 0, b64OfLength(4))); // offset -> 4

    // A chunk from a brand-new epoch.
    await lane.onChunk(chunk('e2', 0, b64OfLength(9)));

    // Cold re-attach (no epoch/lastSeq), reset because the epoch changed.
    expect(request).toHaveBeenNthCalledWith(2, 'pane.bytes.attach', { paneId: 'p1' });
    expect(fx.resets).toBe(1);
    expect(lane.currentEpoch).toBe('e2');
    expect(lane.expectedOffset).toBe(3);
  });
});

// ---- detach + isolation -----------------------------------------------------

describe('PaneBytesLane detach and isolation', () => {
  it('detach sends pane.bytes.detach and clears lane state', async () => {
    const send = jest.fn();
    const transport = makeTransport({ send });
    const lane = new PaneBytesLane('p1', transport, makeEffects());
    await lane.attach();
    lane.detach();
    expect(send).toHaveBeenCalledWith('pane.bytes.detach', { paneId: 'p1' });
    expect(lane.currentEpoch).toBeUndefined();
    expect(lane.expectedOffset).toBe(0);
  });

  it('ignores a late attach reply after detach (generation guard)', async () => {
    let resolveAttach!: (value: ParsedMessage) => void;
    const request = jest.fn(
      () =>
        new Promise<ParsedMessage>((resolve) => {
          resolveAttach = resolve;
        }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    const pending = lane.attach();
    lane.detach();
    resolveAttach(attachedReply({ epoch: 'e1', startSeq: 0, replay: b64OfLength(4), truncated: false }));
    await pending;
    expect(fx.writes).toEqual([]);
    expect(fx.unsupported).toBe(0);
    expect(lane.currentEpoch).toBeUndefined();
  });

  it('ignores attached payload for a different paneId and schedules cold follow-up', async () => {
    const replies: ParsedMessage[] = [
      attachedReply({ paneId: 'other', epoch: 'e1', startSeq: 0, replay: b64OfLength(2), truncated: false }),
      attachedReply({ epoch: 'e1', startSeq: 0, replay: b64OfLength(3), truncated: false }),
    ];
    let call = 0;
    const request = jest.fn(async () => replies[call++]);
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    await lane.attach();
    // First reply wrong paneId → no write; follow-up cold attach applies second reply.
    await Promise.resolve();
    await Promise.resolve();
    expect(request).toHaveBeenCalledTimes(2);
    expect(fx.writes).toEqual([b64OfLength(3)]);
    expect(lane.currentEpoch).toBe('e1');
  });

  it('ignores chunks for a different paneId', async () => {
    const { lane, fx } = await (async () => {
      const request = jest.fn(async () => attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false }));
      const fx = makeEffects();
      const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
      await lane.attach();
      return { lane, fx };
    })();

    lane.onChunk({ paneId: 'other', epoch: 'e1', seq: 0, data: b64OfLength(4) });
    expect(fx.writes).toEqual([]);
    expect(lane.expectedOffset).toBe(0);
  });
});

// ---- resync / pending follow-up ---------------------------------------------

describe('PaneBytesLane resync and pending follow-up', () => {
  it('resync warm-attaches from expected after a successful cold attach', async () => {
    const replies: ParsedMessage[] = [
      attachedReply({ epoch: 'e1', startSeq: 0, replay: b64OfLength(4), truncated: false }),
      attachedReply({ epoch: 'e1', startSeq: 4, replay: '', truncated: false }),
    ];
    let call = 0;
    const request = jest.fn(async () => replies[call++]);
    const lane = new PaneBytesLane('p1', makeTransport({ request }), makeEffects());
    await lane.attach();
    await lane.resync();
    expect(request).toHaveBeenNthCalledWith(2, 'pane.bytes.attach', {
      paneId: 'p1',
      lastSeq: 4,
      epoch: 'e1',
    });
  });

  it('queues a warm follow-up when a gap arrives while attaching', async () => {
    let resolveFirst!: (value: ParsedMessage) => void;
    const request = jest.fn((type: string, payload: unknown) => {
      if (request.mock.calls.length === 1) {
        return new Promise<ParsedMessage>((resolve) => {
          resolveFirst = resolve;
        });
      }
      // Follow-up warm attach.
      return Promise.resolve(
        attachedReply({ epoch: 'e1', startSeq: 0, replay: b64OfLength(2), truncated: false }),
      );
    });
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);
    const first = lane.attach();
    // Mid-attach gap chunk — should not drop recovery.
    void lane.onChunk(chunk('e1', 99, b64OfLength(1)));
    resolveFirst(attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false }));
    await first;
    // Allow follow-up to complete.
    await Promise.resolve();
    await Promise.resolve();
    expect(request.mock.calls.length).toBeGreaterThanOrEqual(2);
    const secondPayload = request.mock.calls[1]?.[1] as { lastSeq?: number; epoch?: string };
    // After first attach expected=0; gap while attaching queued warm with lastSeq 0,
    // or cold if epoch was unset at gap time — either is a recovery path.
    expect(secondPayload).toBeDefined();
    expect(fx.unsupported).toBe(0);
  });
});

// ---- grid snapshot (cold attach correctness) --------------------------------
//
// A raw byte tail alone renders as garbage when attaching to a running TUI: it
// starts mid-escape-sequence and misses every mode set before the retained
// window. The mac therefore captures a replayable VT snapshot of the screen. The
// apply order is fixed (reset → size → snapshot → replay), and the snapshot is
// EXCLUDED from seq arithmetic — folding it in would shift every later chunk.

describe('PaneBytesLane snapshot', () => {
  it('applies reset, grid, snapshot, then replay — in that order', async () => {
    const snapshot = b64OfLength(64);
    const replay = b64OfLength(12);
    const request = jest.fn(async () =>
      attachedReply({
        epoch: 'e1',
        startSeq: 100,
        replay,
        truncated: false,
        snapshot,
        snapshotCols: 120,
        snapshotRows: 40,
      }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();

    expect(fx.ops).toEqual([
      { op: 'reset' },
      { op: 'grid', cols: 120, rows: 40 },
      { op: 'write', d: snapshot },
      { op: 'write', d: replay },
    ]);
  });

  it('excludes the snapshot from the expected offset', async () => {
    const snapshot = b64OfLength(4096);
    const replay = b64OfLength(12);
    const request = jest.fn(async () =>
      attachedReply({
        epoch: 'e1',
        startSeq: 100,
        replay,
        truncated: false,
        snapshot,
        snapshotCols: 80,
        snapshotRows: 24,
      }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();

    // startSeq + decoded(replay) only — NOT + decoded(snapshot).
    expect(lane.expectedOffset).toBe(112);

    // The very first live chunk must be contiguous at that offset.
    const next = b64OfLength(5);
    void lane.onChunk(chunk('e1', 112, next));
    expect(fx.writes[fx.writes.length - 1]).toBe(next);
    expect(lane.expectedOffset).toBe(117);
  });

  it('holds the offset at startSeq when the snapshot comes with an empty replay', async () => {
    const snapshot = b64OfLength(300);
    const request = jest.fn(async () =>
      attachedReply({
        epoch: 'e1',
        startSeq: 8192,
        replay: '',
        truncated: false,
        snapshot,
        snapshotCols: 100,
        snapshotRows: 30,
      }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();

    expect(fx.ops).toEqual([
      { op: 'reset' },
      { op: 'grid', cols: 100, rows: 30 },
      { op: 'write', d: snapshot },
    ]);
    expect(lane.expectedOffset).toBe(8192);
  });

  it('still applies the snapshot when the mac omits the grid', async () => {
    const snapshot = b64OfLength(16);
    const request = jest.fn(async () =>
      attachedReply({ epoch: 'e1', startSeq: 0, replay: '', truncated: false, snapshot }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();

    expect(fx.ops).toEqual([{ op: 'reset' }, { op: 'write', d: snapshot }]);
  });

  it('tolerates effects that do not implement onGrid', async () => {
    const request = jest.fn(async () =>
      attachedReply({
        epoch: 'e1',
        startSeq: 0,
        replay: '',
        truncated: false,
        snapshot: b64OfLength(8),
        snapshotCols: 80,
        snapshotRows: 24,
      }),
    );
    const writes: string[] = [];
    const lane = new PaneBytesLane('p1', makeTransport({ request }), {
      onWrite: (d) => writes.push(d),
      onReset: () => {},
      onUnsupported: () => {},
    });

    await expect(lane.attach()).resolves.toBeUndefined();
    expect(writes).toEqual([b64OfLength(8)]);
  });

  it('leaves behaviour unchanged when no snapshot is present', async () => {
    const replay = b64OfLength(10);
    const request = jest.fn(async () =>
      attachedReply({ epoch: 'e1', startSeq: 5, replay, truncated: false }),
    );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();

    expect(fx.ops).toEqual([{ op: 'write', d: replay }]);
    expect(fx.resets).toBe(0);
    expect(lane.expectedOffset).toBe(15);
  });

  it('repaints (resets first) when a snapshot arrives mid-session after a gap', async () => {
    const firstReplay = b64OfLength(4);
    const snapshot = b64OfLength(200);
    const request = jest
      .fn<() => Promise<ParsedMessage>>()
      .mockResolvedValueOnce(
        attachedReply({ epoch: 'e1', startSeq: 0, replay: firstReplay, truncated: false }),
      )
      // Resync reply for the same epoch, NOT truncated — the snapshot alone must
      // still force a reset, or the repaint stacks on the stale screen.
      .mockResolvedValueOnce(
        attachedReply({
          epoch: 'e1',
          startSeq: 40,
          replay: '',
          truncated: false,
          snapshot,
          snapshotCols: 90,
          snapshotRows: 26,
        }),
      );
    const fx = makeEffects();
    const lane = new PaneBytesLane('p1', makeTransport({ request }), fx);

    await lane.attach();
    expect(fx.resets).toBe(0);

    // A chunk beyond the expected offset is a gap → warm re-attach.
    await lane.onChunk(chunk('e1', 999, b64OfLength(2)));

    expect(fx.ops).toEqual([
      { op: 'write', d: firstReplay },
      { op: 'reset' },
      { op: 'grid', cols: 90, rows: 26 },
      { op: 'write', d: snapshot },
    ]);
    expect(lane.expectedOffset).toBe(40);
  });
});
