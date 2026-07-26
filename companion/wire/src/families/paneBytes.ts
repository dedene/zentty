import { z } from 'zod';

// pane.bytes.* — the raw PTY byte lane (cmux-style streaming).
//
// This is the high-fidelity sibling of the plain-text `pane.*` lane in pane.ts.
// Where `pane.text` ships a debounced, re-rendered viewport snapshot, this lane
// streams the terminal's raw output bytes verbatim so the phone can drive a real
// VT emulator. The phone reconstructs the screen locally; the Mac just forwards
// PTY bytes.
//
// Sequencing model
// ----------------
// - `epoch` is an opaque string minted once per *surface lifetime* on the Mac.
//   It changes whenever the underlying PTY/surface restarts. On any epoch change
//   the phone MUST discard its emulator state and cold-attach again — byte
//   offsets from the old epoch are meaningless against the new stream.
// - `seq` is the BYTE OFFSET of a chunk's first byte within its epoch. It starts
//   at `startSeq` (from `pane.bytes.attached`) and advances by the DECODED byte
//   length of each chunk's `data`. The next expected offset is therefore
//   `seq + decodedByteLength(data)`. The phone detects loss when an incoming
//   chunk's `seq` does not equal its expected offset, and recovers by
//   re-attaching with `lastSeq` set to that expected offset.
// - `lastSeq` is an EXCLUSIVE resume cursor: the first missing byte offset
//   (i.e. the phone's next expected offset after applying contiguous bytes
//   `[0, lastSeq)`). A non-truncated warm reply for the same epoch MUST use
//   `startSeq == lastSeq` and `replay` covering `[lastSeq, …)` through the
//   ring head. Do NOT treat `lastSeq` as the last *included* byte index.
//
// Base64
// ------
// All binary fields (`replay`, `data`) are STANDARD base64 (RFC 4648 §4,
// `+`/`/` alphabet, `=` padding) — matching the other envelope-layer binary
// payloads (`push` sealedPayload, pairing DER keys). NOT base64url; that flavor
// is reserved for the outer relay transport framing (see relay.ts). Empty string
// is a valid encoding of zero bytes (used for an empty `replay`).

/**
 * Max decoded byte length of a single `pane.bytes.chunk` payload before base64
 * encoding. Producers MUST split longer runs across multiple chunks.
 *
 * 32 KiB leaves generous headroom under the relay's 256 KiB frame cap
 * (`maxFrameBytes`, companion/relay/src/config.ts): the raw bytes are base64'd
 * (~×4/3) into the envelope payload, the envelope is E2E-sealed, and the sealed
 * blob is base64'd again (~×4/3) into the outer `relay.frame`. Even the doubled
 * expansion of a full 32 KiB chunk (~58 KiB) stays well inside the cap.
 */
export const PANE_BYTES_MAX_CHUNK_BYTES = 32 * 1024;

/**
 * Max base64 string length for a `chunk.data` field: `ceil(N/3)*4` for
 * N = {@link PANE_BYTES_MAX_CHUNK_BYTES}. Bounds the frame at the schema layer
 * without having to decode.
 */
export const PANE_BYTES_MAX_CHUNK_B64_LEN =
  Math.ceil(PANE_BYTES_MAX_CHUNK_BYTES / 3) * 4;

/**
 * Max decoded byte length of an `attached.replay` tail before base64 encoding.
 * Producers MUST send only the most RECENT bytes that fit and set
 * `truncated: true` when the retained ring is larger.
 *
 * The mac's ring is 1 MiB, so an unbounded cold-attach replay would blow past
 * the relay's 256 KiB frame cap — and the relay enforces that as the WebSocket
 * `maxPayload`, which CLOSES the connection (1009) rather than rejecting the
 * frame. Budget, worst case, for a replay of R raw bytes:
 *
 *   1. `replay` std-base64:            ceil(R/3)*4      ≈ 1.334·R
 *   2. envelope JSON (v/id/type/
 *      replyTo/paneId/epoch/startSeq)  ≤ 512 B
 *   3. session seal                    + 24 B  (8-byte counter || 16-byte tag)
 *   4. sealed → base64url `sealed`     ≈ 1.334×
 *   5. `relay.frame` JSON (type/to/
 *      from, 43-char device ids)       ≤ 256 B
 *
 *   total ≈ (4/3)·((4/3)·R + 512 + 24) + 256 = (16/9)·R + ~971
 *
 * Solving `(16/9)·R + 971 ≤ 262144` gives R ≤ ~143 KiB. But the frame cap is NOT
 * the binding constraint — the per-device byte bucket is. `bytesPerSec` defaults
 * to the same 256 KiB (config.ts:61) and is the bucket's FULL capacity, so a
 * frame sized against `maxFrameBytes` alone eats most of a second's budget in one
 * go. A 143 KiB replay (~254 KiB on the wire) leaves almost nothing, so on a pane
 * that is still producing output the following `pane.bytes.chunk` frames are
 * rate-limited away; the lane sees a seq gap, resyncs, gets another huge replay,
 * and never converges. The pane appears to stall.
 *
 * So size against the bucket instead: 32 KiB raw is ~58 KiB on the wire, ~23% of
 * one second's budget, leaving ample room for live chunks to keep flowing. It
 * matches {@link PANE_BYTES_MAX_CHUNK_BYTES} — one chunk's worth — which is the
 * right unit for a warm resume. Cold attach does not depend on this budget: once
 * a grid snapshot is present the mac sends `replay: ""` and the snapshot carries
 * the screen.
 */
export const PANE_BYTES_MAX_REPLAY_BYTES = 32 * 1024;

/**
 * Max base64 string length for an `attached.replay` field: `ceil(N/3)*4` for
 * N = {@link PANE_BYTES_MAX_REPLAY_BYTES}.
 */
export const PANE_BYTES_MAX_REPLAY_B64_LEN =
  Math.ceil(PANE_BYTES_MAX_REPLAY_BYTES / 3) * 4;

/**
 * Max decoded bytes for an `attached.snapshot`.
 *
 * A snapshot gets a larger budget than a replay — it is what makes cold attach
 * correct, and a cold attach sends `replay: ""` so the two are never charged
 * against the same frame. Composition for a dense screen: ~6 KB of OSC 4
 * palette, plus per-cell SGR-encoded content.
 *
 * But it is sized against the same binding constraint as `replay`: the relay's
 * per-device BYTE BUCKET, not the frame cap. "One-shot, not steady-state" is a
 * trap here — the moment right after a cold attach is exactly when a TUI's
 * redraw burst is densest, so a snapshot that eats the second's budget gets its
 * own follow-up chunks rate-limited away. The phone then sees a gap, re-attaches,
 * hits the capture throttle, and falls back to a byte tail. 48 KiB is ~86 KiB on
 * the wire (~34% of one second), leaving room for the burst to land.
 *
 * Captures over the cap fall back to a plain byte tail rather than being sent —
 * see `CompanionPaneBytesFeed.maxSnapshotBytes`, which must stay in lockstep.
 */
export const PANE_BYTES_MAX_SNAPSHOT_BYTES = 48 * 1024;

/** Max base64 string length for `attached.snapshot`. */
export const PANE_BYTES_MAX_SNAPSHOT_B64_LEN =
  Math.ceil(PANE_BYTES_MAX_SNAPSHOT_BYTES / 3) * 4;

/** Standard-base64 body (RFC 4648 §4). Empty string = zero bytes. */
const Base64Std = z.string().regex(/^[A-Za-z0-9+/]*={0,2}$/, 'standard base64');

/**
 * `pane.bytes.attach` (phone → mac). Request half; the reply is
 * `pane.bytes.attached`, correlated via the envelope `replyTo` (same machinery
 * as `pane.scrollback`).
 *
 * - Cold attach: omit both `lastSeq` and `epoch`. The mac replays whatever tail
 *   it has and streams forward.
 * - Warm re-attach (after a detected gap): carry both `lastSeq` (exclusive
 *   resume cursor — first missing byte) and `epoch`. The mac resumes from
 *   `lastSeq` when the ring still covers it, else replies with `truncated: true`.
 *
 * Partial warm shapes (only `lastSeq` or only `epoch`) are rejected by the
 * schema — both fields are required together, or both absent.
 */
export const PaneBytesAttach = z
  .object({
    paneId: z.string(),
    lastSeq: z.number().int().gte(0).optional(),
    epoch: z.string().optional(),
  })
  .superRefine((value, ctx) => {
    const hasLast = value.lastSeq !== undefined;
    const hasEpoch = value.epoch !== undefined;
    if (hasLast !== hasEpoch) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'warm attach requires both lastSeq and epoch; cold attach omits both',
        path: hasLast ? ['epoch'] : ['lastSeq'],
      });
    }
  });

/**
 * `pane.bytes.attached` (mac → phone). Reply half of `pane.bytes.attach`,
 * carried with `replyTo` = the attach frame's envelope `id`.
 *
 * - `epoch`: the current surface epoch. If it differs from the phone's, the
 *   phone resets its emulator before applying `replay`.
 * - `startSeq`: the byte offset of the FIRST byte in `replay`. Subsequent
 *   `pane.bytes.chunk.seq` values continue from `startSeq + decoded(replay)`.
 * - `replay`: standard-base64 tail-ring bytes from `startSeq`, decoded length ≤
 *   {@link PANE_BYTES_MAX_REPLAY_BYTES}. May be empty (`""`) — e.g. a cold
 *   attach to a surface with no buffered output yet. When the mac's ring holds
 *   more than the cap it sends the most recent bytes that fit and sets
 *   `truncated: true`.
 * - `truncated`: `true` when the ring could NOT cover the requested resume
 *   point (`lastSeq`/`epoch` fell off the back of the ring, or the epoch
 *   changed). The phone MUST reset its emulator before writing `replay`, since
 *   `replay` is then a fresh tail rather than a continuation.
 * - `snapshot`: a self-contained VT byte stream reproducing the pane's screen
 *   (see below). Present on cold attach; absent on a clean warm resume.
 * - `snapshotRows` / `snapshotCols`: the mac's grid at capture time.
 *
 * ## Applying a snapshot
 *
 * A raw byte tail cannot reconstruct a TUI screen — replaying it into a fresh
 * emulator starts mid-escape-sequence and misses every mode set before the
 * retained window. So when `snapshot` is present the phone MUST:
 *
 *   1. reset its emulator,
 *   2. size it to `snapshotCols` × `snapshotRows`,
 *   3. write `snapshot`,
 *   4. write `replay` (usually `""` when a snapshot is present).
 *
 * The snapshot is EXCLUDED from seq arithmetic: `startSeq` still describes
 * `replay`'s first byte only, and the phone's next expected offset stays
 * `startSeq + decoded(replay)`. Do not concatenate the snapshot into `replay` —
 * that would shift the offset and corrupt the very first chunk.
 *
 * `truncated` remains for compatibility but is advisory when a snapshot is
 * present: the snapshot IS the resync.
 *
 * The mac is authoritative for grid size on this lane. The phone letterboxes to
 * `snapshotCols` × `snapshotRows` while mirroring read-only and only fits to its
 * own grid once it holds a control lease — at which point the mac follows and
 * re-snapshots. Any other arrangement makes the snapshot and the live tail
 * disagree about reflow.
 */
export const PaneBytesAttached = z.object({
  paneId: z.string(),
  epoch: z.string(),
  startSeq: z.number().int().gte(0),
  replay: Base64Std.max(PANE_BYTES_MAX_REPLAY_B64_LEN),
  truncated: z.boolean(),
  snapshot: Base64Std.max(PANE_BYTES_MAX_SNAPSHOT_B64_LEN).optional(),
  snapshotRows: z.number().int().positive().optional(),
  snapshotCols: z.number().int().positive().optional(),
});

/**
 * `pane.bytes.chunk` (mac → phone). One run of raw PTY output.
 *
 * - `epoch`: the surface epoch these bytes belong to. A chunk whose `epoch` the
 *   phone doesn't recognize means it missed an epoch change → cold-attach.
 * - `seq`: byte offset of `data`'s first byte within `epoch` (see sequencing
 *   model above). Loss is detected when `seq !=` the phone's expected offset.
 * - `data`: standard-base64 raw bytes, decoded length ≤
 *   {@link PANE_BYTES_MAX_CHUNK_BYTES}.
 */
export const PaneBytesChunk = z.object({
  paneId: z.string(),
  epoch: z.string(),
  seq: z.number().int().gte(0),
  data: Base64Std.max(PANE_BYTES_MAX_CHUNK_B64_LEN),
});

/** `pane.bytes.detach` (phone → mac). Stop streaming this pane's byte lane. */
export const PaneBytesDetach = z.object({
  paneId: z.string(),
});

export const paneBytesMessages = {
  'pane.bytes.attach': PaneBytesAttach,
  'pane.bytes.attached': PaneBytesAttached,
  'pane.bytes.chunk': PaneBytesChunk,
  'pane.bytes.detach': PaneBytesDetach,
} as const;
