import { describe, expect, it } from 'vitest';
import { canonicalStringify } from '../src/index';

describe('canonicalStringify', () => {
  it('sorts object keys regardless of input order', () => {
    const a = canonicalStringify({ b: 1, a: 2, c: 3 });
    const b = canonicalStringify({ c: 3, a: 2, b: 1 });
    expect(a).toBe(b);
    expect(a).toBe('{"a":2,"b":1,"c":3}');
  });

  it('sorts nested objects and preserves array order', () => {
    const out = canonicalStringify({
      z: [{ y: 1, x: 2 }],
      a: { d: 4, c: 3 },
    });
    expect(out).toBe('{"a":{"c":3,"d":4},"z":[{"x":2,"y":1}]}');
  });

  it('drops undefined values', () => {
    expect(canonicalStringify({ a: 1, b: undefined })).toBe('{"a":1}');
  });
});
