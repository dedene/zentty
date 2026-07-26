import { describe, expect, it } from '@jest/globals';

import { coalescePaneText, withScrollback, type PaneTextFrame, type PaneTextState } from '../paneText';

function frame(overrides: Partial<PaneTextFrame> & { seq: number; viewport: string }): PaneTextFrame {
  return {
    paneId: 'p1',
    gridCols: 80,
    gridRows: 24,
    truncatedScrollback: false,
    ...overrides,
  };
}

describe('coalescePaneText', () => {
  it('adopts the first frame', () => {
    const next = coalescePaneText(undefined, frame({ seq: 1, viewport: 'hello' }));
    expect(next).not.toBeNull();
    expect(next?.seq).toBe(1);
    expect(next?.viewport).toBe('hello');
  });

  it('applies a strictly newer seq', () => {
    const prev = coalescePaneText(undefined, frame({ seq: 5, viewport: 'a' }))!;
    const next = coalescePaneText(prev, frame({ seq: 6, viewport: 'b' }));
    expect(next?.seq).toBe(6);
    expect(next?.viewport).toBe('b');
  });

  it('drops a stale (older) seq', () => {
    const prev = coalescePaneText(undefined, frame({ seq: 10, viewport: 'fresh' }))!;
    const next = coalescePaneText(prev, frame({ seq: 4, viewport: 'stale' }));
    expect(next).toBeNull();
  });

  it('drops a duplicate seq', () => {
    const prev = coalescePaneText(undefined, frame({ seq: 7, viewport: 'x' }))!;
    const next = coalescePaneText(prev, frame({ seq: 7, viewport: 'y' }));
    expect(next).toBeNull();
  });

  it('preserves scrollback across a viewport update', () => {
    const seeded: PaneTextState = withScrollback(
      coalescePaneText(undefined, frame({ seq: 1, viewport: 'v1' }))!,
      'old lines',
    );
    const next = coalescePaneText(seeded, frame({ seq: 2, viewport: 'v2' }));
    expect(next?.viewport).toBe('v2');
    expect(next?.scrollback).toBe('old lines');
  });

  it('carries grid metrics through', () => {
    const next = coalescePaneText(undefined, frame({ seq: 1, viewport: 'v', gridCols: 45, gridRows: 60, truncatedScrollback: true }));
    expect(next?.gridCols).toBe(45);
    expect(next?.gridRows).toBe(60);
    expect(next?.truncatedScrollback).toBe(true);
  });
});
