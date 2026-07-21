/**
 * Pure reducer for the Conversation tab: fold `transcript.snapshot` /
 * `transcript.delta` / `transcript.unavailable` frames into a render model.
 *
 * Deltas upsert by entry `id` (a `tool_use` entry can be revised when its result
 * lands), so replaying a delta is idempotent and out-of-order status updates
 * converge. Kept UI-free so ordering is unit-tested in isolation.
 */

import type { TranscriptEntry, TranscriptUnavailableReason } from '@zentty/wire';

export type TranscriptStatus = 'idle' | 'loading' | 'active' | 'unavailable';

export interface TranscriptState {
  status: TranscriptStatus;
  sessionId?: string;
  entries: TranscriptEntry[];
  truncated: boolean;
  unavailableReason?: TranscriptUnavailableReason;
}

export const initialTranscript: TranscriptState = {
  status: 'idle',
  entries: [],
  truncated: false,
};

/** Mark the transcript as loading (subscribe sent, awaiting the snapshot). */
export function loadingTranscript(prev: TranscriptState = initialTranscript): TranscriptState {
  return { ...prev, status: 'loading', unavailableReason: undefined };
}

/** Adopt a full snapshot as the new baseline. */
export function applyTranscriptSnapshot(payload: {
  sessionId: string;
  entries: TranscriptEntry[];
  truncated: boolean;
}): TranscriptState {
  return {
    status: 'active',
    sessionId: payload.sessionId,
    entries: [...payload.entries],
    truncated: payload.truncated,
    unavailableReason: undefined,
  };
}

/** Append/upsert delta entries by id. A late `unavailable` can be superseded by
 * a fresh delta, so this flips the state back to `active`. */
export function applyTranscriptDelta(
  state: TranscriptState,
  payload: { entries: TranscriptEntry[] },
): TranscriptState {
  if (payload.entries.length === 0) {
    return state;
  }
  const indexById = new Map(state.entries.map((entry, i) => [entry.id, i]));
  const entries = state.entries.slice();
  for (const entry of payload.entries) {
    const at = indexById.get(entry.id);
    if (at === undefined) {
      indexById.set(entry.id, entries.length);
      entries.push(entry);
    } else {
      entries[at] = entry;
    }
  }
  return {
    ...state,
    status: 'active',
    entries,
    unavailableReason: undefined,
  };
}

/** The pane has no transcript (no adapter / session ended / file gone). */
export function applyTranscriptUnavailable(
  state: TranscriptState,
  reason: TranscriptUnavailableReason,
): TranscriptState {
  return { ...state, status: 'unavailable', unavailableReason: reason };
}
