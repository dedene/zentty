/**
 * Pure dashboard state: fold `dashboard.snapshot` / `dashboard.delta` frames into
 * a worklane/pane tree, and derive the view ordering the Dashboard screen renders.
 *
 * This module is deliberately UI-free and side-effect-free so the ordering and
 * staleness rules — the parts that are easy to get subtly wrong — are unit-tested
 * in isolation (see __tests__/dashboard.test.ts).
 */

import type { PaneSummary } from '@zentty/wire';

/** One worklane group, mirroring the wire `Worklane` shape. */
export interface Worklane {
  id: string;
  title: string;
  windowId: number;
  /** Derived: any contained pane requires human attention. */
  attention: boolean;
  panes: PaneSummary[];
}

export interface DashboardSnapshotPayload {
  worklanes: Worklane[];
}

export interface DashboardDeltaPayload {
  updated: PaneSummary[];
  removedPaneIds: string[];
}

/** Connection lifecycle as the store tracks it per Mac. */
export type ConnState = 'connecting' | 'connected' | 'offline';

/** Recompute a worklane's attention flag from its current panes. */
function withDerivedAttention(worklane: Worklane): Worklane {
  return { ...worklane, attention: worklane.panes.some((p) => p.requiresHumanAttention) };
}

/**
 * Adopt a full snapshot as the new baseline. Copies the arrays (callers must not
 * mutate the model in place) and re-derives each worklane's attention flag so it
 * always agrees with its panes.
 */
export function applySnapshot(payload: DashboardSnapshotPayload): Worklane[] {
  return payload.worklanes.map((w) =>
    withDerivedAttention({ ...w, panes: [...w.panes] }),
  );
}

/**
 * Apply an incremental delta to the current tree, returning a new array.
 *
 * - `removedPaneIds` are dropped from every worklane.
 * - each `updated` pane replaces the pane with its `paneId` (moving worklanes if
 *   its `worklaneId` changed), or is appended to its worklane when new.
 * - a worklane referenced by an updated pane but not yet present is created as a
 *   minimal placeholder (its title fills in on the next snapshot).
 * - worklanes left with no panes are dropped.
 */
export function applyDelta(current: Worklane[], delta: DashboardDeltaPayload): Worklane[] {
  const removed = new Set(delta.removedPaneIds);

  // Where each pane currently lives, so an in-place update keeps its row position
  // and a worklane change relocates it rather than duplicating it.
  const currentWorklaneOf = new Map<string, string>();
  for (const worklane of current) {
    for (const pane of worklane.panes) {
      currentWorklaneOf.set(pane.paneId, worklane.id);
    }
  }

  const next: Worklane[] = current.map((w) => ({
    ...w,
    panes: w.panes.filter((p) => !removed.has(p.paneId)),
  }));
  const worklaneById = new Map(next.map((w) => [w.id, w]));

  for (const pane of delta.updated) {
    if (removed.has(pane.paneId)) {
      continue;
    }
    const previousWorklaneId = currentWorklaneOf.get(pane.paneId);

    if (previousWorklaneId === pane.worklaneId) {
      // Same worklane: swap in place, preserving the row's position.
      const worklane = worklaneById.get(previousWorklaneId);
      if (worklane) {
        const index = worklane.panes.findIndex((p) => p.paneId === pane.paneId);
        if (index >= 0) {
          worklane.panes[index] = pane;
        } else {
          worklane.panes.push(pane);
        }
      }
      continue;
    }

    // New or relocated: drop it from any old worklane, then append to the target.
    if (previousWorklaneId !== undefined) {
      const old = worklaneById.get(previousWorklaneId);
      if (old) {
        old.panes = old.panes.filter((p) => p.paneId !== pane.paneId);
      }
    }
    let target = worklaneById.get(pane.worklaneId);
    if (!target) {
      target = { id: pane.worklaneId, title: pane.worklaneId, windowId: 0, attention: false, panes: [] };
      worklaneById.set(target.id, target);
      next.push(target);
    }
    target.panes.push(pane);
  }

  return next
    .filter((w) => w.panes.length > 0)
    .map(withDerivedAttention);
}

/**
 * Order panes for display: rows that require human attention are pinned to the
 * top, each group keeping its incoming (server) order. Partitioning (rather than
 * a comparator) guarantees stability regardless of the engine's sort.
 */
export function orderPanes(panes: PaneSummary[]): PaneSummary[] {
  const attention: PaneSummary[] = [];
  const rest: PaneSummary[] = [];
  for (const pane of panes) {
    (pane.requiresHumanAttention ? attention : rest).push(pane);
  }
  return [...attention, ...rest];
}

/**
 * Order worklane sections for display: sections containing an attention pane come
 * first (stable), and every section's panes are ordered via {@link orderPanes}.
 */
export function orderWorklanes(worklanes: Worklane[]): Worklane[] {
  const withOrderedPanes = worklanes.map((w) => ({ ...w, panes: orderPanes(w.panes) }));
  const attention: Worklane[] = [];
  const rest: Worklane[] = [];
  for (const w of withOrderedPanes) {
    (w.attention ? attention : rest).push(w);
  }
  return [...attention, ...rest];
}

/** Total panes awaiting a human across all worklanes — drives the header count. */
export function countAttention(worklanes: Worklane[]): number {
  let n = 0;
  for (const w of worklanes) {
    for (const p of w.panes) {
      if (p.requiresHumanAttention) {
        n += 1;
      }
    }
  }
  return n;
}

/**
 * Staleness: the dashboard is stale when it is showing cached data while not
 * connected. A fresh, never-connected view with no cached data is not "stale" —
 * it is simply loading — so cached data is required.
 */
export function isStale(status: ConnState, hasCachedData: boolean): boolean {
  return status !== 'connected' && hasCachedData;
}
