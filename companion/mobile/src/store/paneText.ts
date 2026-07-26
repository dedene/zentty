/**
 * Pure coalescing buffer for `pane.text` frames.
 *
 * The Mac streams a full viewport snapshot per debounced render with a monotonic
 * `seq` per pane. The network can reorder or redeliver, so the phone keeps only
 * the highest `seq` seen and drops anything stale — a late frame must never
 * overwrite a newer viewport. Scrollback (fetched separately via
 * `pane.scrollback`) is preserved across viewport updates.
 */

import { PaneText } from '@zentty/wire';

/** The decoded `pane.text` payload (the wire package exports only the schema). */
export type PaneTextFrame = ReturnType<typeof PaneText.parse>;

/** The rendered terminal state for one pane. */
export interface PaneTextState {
  /** Highest `seq` applied so far (monotonic per pane). */
  seq: number;
  /** Full viewport text at `seq`. */
  viewport: string;
  cursorRow?: number;
  gridCols: number;
  gridRows: number;
  truncatedScrollback: boolean;
  /** Bounded scrollback fetched on pull-to-top; independent of the viewport seq. */
  scrollback?: string;
}

/**
 * Fold an incoming `pane.text` frame into the current state.
 *
 * Returns the new state, or `null` when the frame is stale (its `seq` is not
 * greater than what we already have) so the caller can skip the re-render.
 */
export function coalescePaneText(
  prev: PaneTextState | undefined,
  incoming: PaneTextFrame,
): PaneTextState | null {
  if (prev && incoming.seq <= prev.seq) {
    return null;
  }
  return {
    seq: incoming.seq,
    viewport: incoming.viewport,
    cursorRow: incoming.cursorRow,
    gridCols: incoming.gridCols,
    gridRows: incoming.gridRows,
    truncatedScrollback: incoming.truncatedScrollback,
    scrollback: prev?.scrollback,
  };
}

/** Attach freshly fetched scrollback without disturbing the live viewport. */
export function withScrollback(
  prev: PaneTextState | undefined,
  scrollback: string,
): PaneTextState {
  if (!prev) {
    return {
      seq: -1,
      viewport: '',
      gridCols: 0,
      gridRows: 0,
      truncatedScrollback: false,
      scrollback,
    };
  }
  return { ...prev, scrollback };
}
