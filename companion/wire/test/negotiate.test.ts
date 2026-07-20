import { describe, expect, it } from 'vitest';
import { MIN_SUPPORTED, PROTOCOL_VERSION, negotiateVersion } from '../src/index';

describe('negotiateVersion', () => {
  it('picks the lower of the two maxima', () => {
    expect(negotiateVersion({ min: 1, max: 3 }, { min: 1, max: 2 })).toBe(2);
    expect(negotiateVersion({ min: 1, max: 1 }, { min: 1, max: 5 })).toBe(1);
  });

  it('returns the shared version when windows match', () => {
    expect(negotiateVersion({ min: 1, max: 1 }, { min: 1, max: 1 })).toBe(1);
  });

  it('returns null when the effective version is below a side minimum', () => {
    // b can only speak >=3 but the shared max is 2.
    expect(negotiateVersion({ min: 1, max: 2 }, { min: 3, max: 4 })).toBeNull();
    expect(negotiateVersion({ min: 4, max: 5 }, { min: 1, max: 2 })).toBeNull();
  });

  it('agrees with this build advertising [MIN_SUPPORTED, PROTOCOL_VERSION]', () => {
    const self = { min: MIN_SUPPORTED, max: PROTOCOL_VERSION };
    expect(negotiateVersion(self, self)).toBe(PROTOCOL_VERSION);
  });
});
