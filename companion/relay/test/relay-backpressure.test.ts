import { describe, expect, it } from 'vitest';
import { overBackpressureLimit } from '../src/server.js';

// send() drops a frame when the target socket's bufferedAmount exceeds the cap,
// instead of buffering unboundedly for a slow consumer. Forcing real TCP
// backpressure is OS-dependent and flaky, so the drop rule is factored into this
// pure predicate and asserted directly.

describe('backpressure guard', () => {
  const cap = 4 * 1024 * 1024;

  it('does not drop while buffered bytes are at or under the cap', () => {
    expect(overBackpressureLimit(0, cap)).toBe(false);
    expect(overBackpressureLimit(cap, cap)).toBe(false);
    expect(overBackpressureLimit(cap - 1, cap)).toBe(false);
  });

  it('drops once buffered bytes exceed the cap', () => {
    expect(overBackpressureLimit(cap + 1, cap)).toBe(true);
    expect(overBackpressureLimit(cap * 2, cap)).toBe(true);
  });

  it('a zero cap drops any pending buffer (aggressive shedding)', () => {
    expect(overBackpressureLimit(0, 0)).toBe(false);
    expect(overBackpressureLimit(1, 0)).toBe(true);
  });
});
