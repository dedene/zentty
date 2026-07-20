import { describe, expect, it } from '@jest/globals';

import type { PaneSummary } from '@zentty/wire';

import {
  applyDelta,
  applySnapshot,
  countAttention,
  isStale,
  orderPanes,
  orderWorklanes,
  type Worklane,
} from '../dashboard';

function pane(overrides: Partial<PaneSummary> & { paneId: string; worklaneId: string }): PaneSummary {
  return {
    title: overrides.paneId,
    state: 'running',
    interactionKind: 'none',
    requiresHumanAttention: false,
    workingDirectory: '/tmp',
    hasTranscript: false,
    ...overrides,
  };
}

function worklane(id: string, panes: PaneSummary[]): Worklane {
  return { id, title: id, windowId: 1, attention: false, panes };
}

describe('applySnapshot', () => {
  it('derives worklane attention from its panes', () => {
    const result = applySnapshot({
      worklanes: [
        worklane('w1', [pane({ paneId: 'a', worklaneId: 'w1', requiresHumanAttention: true })]),
        worklane('w2', [pane({ paneId: 'b', worklaneId: 'w2' })]),
      ],
    });
    expect(result[0].attention).toBe(true);
    expect(result[1].attention).toBe(false);
  });

  it('copies pane arrays so the source is not mutated by later deltas', () => {
    const source = { worklanes: [worklane('w1', [pane({ paneId: 'a', worklaneId: 'w1' })])] };
    const model = applySnapshot(source);
    applyDelta(model, { updated: [pane({ paneId: 'c', worklaneId: 'w1' })], removedPaneIds: [] });
    expect(source.worklanes[0].panes).toHaveLength(1);
  });
});

describe('applyDelta', () => {
  const base = () =>
    applySnapshot({
      worklanes: [
        worklane('w1', [
          pane({ paneId: 'a', worklaneId: 'w1', state: 'running' }),
          pane({ paneId: 'b', worklaneId: 'w1' }),
        ]),
        worklane('w2', [pane({ paneId: 'c', worklaneId: 'w2' })]),
      ],
    });

  it('replaces an updated pane in place by paneId', () => {
    const next = applyDelta(base(), {
      updated: [pane({ paneId: 'a', worklaneId: 'w1', state: 'needsInput', requiresHumanAttention: true })],
      removedPaneIds: [],
    });
    const w1 = next.find((w) => w.id === 'w1')!;
    expect(w1.panes.map((p) => p.paneId)).toEqual(['a', 'b']);
    expect(w1.panes.find((p) => p.paneId === 'a')!.state).toBe('needsInput');
    expect(w1.attention).toBe(true);
  });

  it('appends a genuinely new pane to its worklane', () => {
    const next = applyDelta(base(), {
      updated: [pane({ paneId: 'd', worklaneId: 'w1' })],
      removedPaneIds: [],
    });
    expect(next.find((w) => w.id === 'w1')!.panes.map((p) => p.paneId)).toEqual(['a', 'b', 'd']);
  });

  it('removes panes and drops a worklane left empty', () => {
    const next = applyDelta(base(), { updated: [], removedPaneIds: ['c'] });
    expect(next.map((w) => w.id)).toEqual(['w1']);
  });

  it('relocates a pane whose worklaneId changed', () => {
    const next = applyDelta(base(), {
      updated: [pane({ paneId: 'a', worklaneId: 'w2' })],
      removedPaneIds: [],
    });
    expect(next.find((w) => w.id === 'w1')!.panes.map((p) => p.paneId)).toEqual(['b']);
    expect(next.find((w) => w.id === 'w2')!.panes.map((p) => p.paneId)).toEqual(['c', 'a']);
  });

  it('creates a placeholder worklane for an unknown target', () => {
    const next = applyDelta(base(), {
      updated: [pane({ paneId: 'z', worklaneId: 'w9' })],
      removedPaneIds: [],
    });
    const w9 = next.find((w) => w.id === 'w9');
    expect(w9).toBeDefined();
    expect(w9!.panes.map((p) => p.paneId)).toEqual(['z']);
  });

  it('clears the attention flag when the last waiting pane resolves', () => {
    const withAttention = applySnapshot({
      worklanes: [
        worklane('w1', [pane({ paneId: 'a', worklaneId: 'w1', requiresHumanAttention: true })]),
      ],
    });
    const next = applyDelta(withAttention, {
      updated: [pane({ paneId: 'a', worklaneId: 'w1', requiresHumanAttention: false })],
      removedPaneIds: [],
    });
    expect(next[0].attention).toBe(false);
  });
});

describe('orderPanes', () => {
  it('pins attention panes to the top while preserving order within each group', () => {
    const ordered = orderPanes([
      pane({ paneId: 'a', worklaneId: 'w1' }),
      pane({ paneId: 'b', worklaneId: 'w1', requiresHumanAttention: true }),
      pane({ paneId: 'c', worklaneId: 'w1' }),
      pane({ paneId: 'd', worklaneId: 'w1', requiresHumanAttention: true }),
    ]);
    expect(ordered.map((p) => p.paneId)).toEqual(['b', 'd', 'a', 'c']);
  });

  it('is a no-op ordering when nothing needs attention', () => {
    const input = [
      pane({ paneId: 'a', worklaneId: 'w1' }),
      pane({ paneId: 'b', worklaneId: 'w1' }),
    ];
    expect(orderPanes(input).map((p) => p.paneId)).toEqual(['a', 'b']);
  });
});

describe('orderWorklanes', () => {
  it('floats worklanes with attention above the rest and orders their panes', () => {
    const model = applySnapshot({
      worklanes: [
        worklane('calm', [pane({ paneId: 'a', worklaneId: 'calm' })]),
        worklane('busy', [
          pane({ paneId: 'b', worklaneId: 'busy' }),
          pane({ paneId: 'c', worklaneId: 'busy', requiresHumanAttention: true }),
        ]),
      ],
    });
    const ordered = orderWorklanes(model);
    expect(ordered.map((w) => w.id)).toEqual(['busy', 'calm']);
    expect(ordered[0].panes.map((p) => p.paneId)).toEqual(['c', 'b']);
  });
});

describe('countAttention', () => {
  it('counts every pane awaiting a human across worklanes', () => {
    const model = applySnapshot({
      worklanes: [
        worklane('w1', [
          pane({ paneId: 'a', worklaneId: 'w1', requiresHumanAttention: true }),
          pane({ paneId: 'b', worklaneId: 'w1' }),
        ]),
        worklane('w2', [pane({ paneId: 'c', worklaneId: 'w2', requiresHumanAttention: true })]),
      ],
    });
    expect(countAttention(model)).toBe(2);
  });
});

describe('isStale', () => {
  it('is stale when disconnected with cached data', () => {
    expect(isStale('offline', true)).toBe(true);
    expect(isStale('connecting', true)).toBe(true);
  });

  it('is not stale while connected', () => {
    expect(isStale('connected', true)).toBe(false);
  });

  it('is not stale when there is no cached data to show (just loading)', () => {
    expect(isStale('connecting', false)).toBe(false);
    expect(isStale('offline', false)).toBe(false);
  });
});
