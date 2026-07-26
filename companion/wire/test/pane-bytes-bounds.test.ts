import { describe, expect, it } from 'vitest';
import {
  PANE_BYTES_MAX_CHUNK_B64_LEN,
  PANE_BYTES_MAX_CHUNK_BYTES,
  PANE_BYTES_MAX_REPLAY_B64_LEN,
  PANE_BYTES_MAX_REPLAY_BYTES,
  PANE_BYTES_MAX_SNAPSHOT_B64_LEN,
  PANE_BYTES_MAX_SNAPSHOT_BYTES,
  safeParseMessage,
} from '../src/index';

/**
 * The relay's default `maxFrameBytes` (companion/relay/src/config.ts), mirrored
 * here rather than imported — the wire package must not depend on the server.
 */
const RELAY_MAX_FRAME_BYTES = 256 * 1024;

/**
 * The relay's default per-device `bytesPerSec` (companion/relay/src/config.ts),
 * which is also the token bucket's FULL capacity — so this is how many bytes one
 * device may send in a single second, not just a steady-state rate.
 */
const RELAY_BYTES_PER_SEC = 256 * 1024;

/** Base64 body of exactly `len` chars (padding-free, so any length is legal). */
function b64OfLength(len: number): string {
  return 'A'.repeat(len);
}

function attached(replay: string): unknown {
  return {
    v: 1,
    id: 'b2c3d4e5-0001-4000-8000-000000000001',
    type: 'pane.bytes.attached',
    replyTo: 'a1b2c3d4-0001-4000-8000-000000000001',
    payload: {
      paneId: 'pn_3f2a9c1e',
      epoch: 'ep_9c1e8b47',
      startSeq: 0,
      replay,
      truncated: true,
    },
  };
}

/** (4/3)·((4/3)·R + envelope + seal) + relay framing — see the budget comment
 * on PANE_BYTES_MAX_REPLAY_BYTES. */
function worstCaseWireBytes(b64Len: number): number {
  return Math.ceil(((b64Len + 512 + 24) * 4) / 3) + 256;
}

describe('pane.bytes size bounds', () => {
  it('accepts a replay at exactly the cap', () => {
    const result = safeParseMessage(attached(b64OfLength(PANE_BYTES_MAX_REPLAY_B64_LEN)));
    expect(result.success).toBe(true);
  });

  it('rejects an oversize replay', () => {
    // The bug this guards: the mac's 1 MiB ring base64'd whole into `replay`
    // exceeds the relay's frame cap, and the relay CLOSES such connections.
    const result = safeParseMessage(
      attached(b64OfLength(PANE_BYTES_MAX_REPLAY_B64_LEN + 1)),
    );
    expect(result.success).toBe(false);
  });

  it('rejects a whole-ring replay', () => {
    const wholeRing = Math.ceil((1024 * 1024) / 3) * 4;
    expect(safeParseMessage(attached(b64OfLength(wholeRing))).success).toBe(false);
  });

  it('rejects an oversize chunk', () => {
    const chunk = (data: string) => ({
      v: 1,
      id: 'b2c3d4e5-0002-4000-8000-000000000002',
      type: 'pane.bytes.chunk',
      payload: { paneId: 'pn_3f2a9c1e', epoch: 'ep_9c1e8b47', seq: 0, data },
    });
    expect(safeParseMessage(chunk(b64OfLength(PANE_BYTES_MAX_CHUNK_B64_LEN))).success).toBe(
      true,
    );
    expect(
      safeParseMessage(chunk(b64OfLength(PANE_BYTES_MAX_CHUNK_B64_LEN + 1))).success,
    ).toBe(false);
  });

  it('keeps the worst-case wire expansion under the relay frame cap', () => {
    expect(worstCaseWireBytes(PANE_BYTES_MAX_REPLAY_B64_LEN)).toBeLessThan(
      RELAY_MAX_FRAME_BYTES,
    );
  });

  it('leaves most of a second of byte budget for the chunks that follow', () => {
    // The frame cap is not the binding constraint — the per-device byte bucket
    // is, and it has the same size as its ENTIRE one-second capacity. An attach
    // sized only against the frame cap starves the live chunks that follow it:
    // they get rate-limited, the lane sees a seq gap, resyncs, and draws another
    // huge replay. The pane never converges. Keep an attach to a quarter of the
    // budget so several chunks still fit in the same second.
    const attachCost = worstCaseWireBytes(PANE_BYTES_MAX_REPLAY_B64_LEN);
    expect(attachCost).toBeLessThan(RELAY_BYTES_PER_SEC / 4);

    const chunkCost = worstCaseWireBytes(PANE_BYTES_MAX_CHUNK_B64_LEN);
    expect(attachCost + chunkCost * 3).toBeLessThan(RELAY_BYTES_PER_SEC);
  });
});

/**
 * Cold attach carries a replayable grid snapshot. It is optional (a clean warm
 * resume omits it), self-bounded, and never charged against the same frame as a
 * replay — the mac sends `replay: ""` alongside it.
 */
describe('pane.bytes.attached snapshot fields', () => {
  function attachedWithSnapshot(extra: Record<string, unknown>): unknown {
    return {
      v: 1,
      id: 'b2c3d4e5-0003-4000-8000-000000000003',
      type: 'pane.bytes.attached',
      replyTo: 'a1b2c3d4-0001-4000-8000-000000000001',
      payload: {
        paneId: 'pn_3f2a9c1e',
        epoch: 'ep_9c1e8b47',
        startSeq: 4096,
        replay: '',
        truncated: false,
        ...extra,
      },
    };
  }

  it('accepts an attached frame with no snapshot at all (warm resume)', () => {
    expect(safeParseMessage(attachedWithSnapshot({})).success).toBe(true);
  });

  it('accepts a snapshot with its grid', () => {
    const result = safeParseMessage(
      attachedWithSnapshot({
        snapshot: b64OfLength(4096),
        snapshotCols: 120,
        snapshotRows: 40,
      }),
    );
    expect(result.success).toBe(true);
  });

  it('derives the base64 cap from the byte cap', () => {
    expect(PANE_BYTES_MAX_SNAPSHOT_B64_LEN).toBe(
      Math.ceil(PANE_BYTES_MAX_SNAPSHOT_BYTES / 3) * 4,
    );
    // A snapshot gets a bigger budget than a replay: it is a one-shot cold-attach
    // cost, not a steady-state one.
    expect(PANE_BYTES_MAX_SNAPSHOT_BYTES).toBeGreaterThan(PANE_BYTES_MAX_REPLAY_BYTES);
  });

  it('accepts a snapshot at exactly the cap', () => {
    expect(
      safeParseMessage(
        attachedWithSnapshot({ snapshot: b64OfLength(PANE_BYTES_MAX_SNAPSHOT_B64_LEN) }),
      ).success,
    ).toBe(true);
  });

  it('rejects an oversize snapshot', () => {
    expect(
      safeParseMessage(
        attachedWithSnapshot({ snapshot: b64OfLength(PANE_BYTES_MAX_SNAPSHOT_B64_LEN + 1) }),
      ).success,
    ).toBe(false);
  });

  it('rejects a non-base64 snapshot', () => {
    expect(safeParseMessage(attachedWithSnapshot({ snapshot: 'not base64!' })).success).toBe(
      false,
    );
  });

  it('rejects a zero or negative grid', () => {
    expect(safeParseMessage(attachedWithSnapshot({ snapshotCols: 0 })).success).toBe(false);
    expect(safeParseMessage(attachedWithSnapshot({ snapshotRows: -1 })).success).toBe(false);
  });

  it('rejects a fractional grid', () => {
    expect(safeParseMessage(attachedWithSnapshot({ snapshotRows: 24.5 })).success).toBe(false);
  });

  it('keeps a snapshot-carrying attach inside the relay frame cap', () => {
    // A snapshot attach sends `replay: ""`, so only the snapshot is in flight.
    expect(worstCaseWireBytes(PANE_BYTES_MAX_SNAPSHOT_B64_LEN)).toBeLessThan(
      RELAY_MAX_FRAME_BYTES,
    );
  });
});
