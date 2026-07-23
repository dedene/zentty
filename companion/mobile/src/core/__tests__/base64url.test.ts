/** @jest-environment node */
import { describe, expect, it } from '@jest/globals';

import { decodeBase64Url, encodeBase64Url, isValidUnpaddedBase64Url } from '../base64url';

describe('base64url', () => {
  it('encodes known small inputs unpadded', () => {
    expect(encodeBase64Url(new Uint8Array([]))).toBe('');
    expect(encodeBase64Url(new Uint8Array([0x00]))).toBe('AA');
    expect(encodeBase64Url(new Uint8Array([0xff, 0xff]))).toBe('__8');
    expect(encodeBase64Url(new Uint8Array([0xfb, 0xff, 0xbf]))).toBe('-_-_');
  });

  it('matches Node Buffer base64url over random inputs', () => {
    for (let len = 0; len < 40; len += 1) {
      const bytes = new Uint8Array(len);
      for (let i = 0; i < len; i += 1) {
        bytes[i] = (i * 37 + len * 11) & 0xff;
      }
      const expected = Buffer.from(bytes).toString('base64url');
      expect(encodeBase64Url(bytes)).toBe(expected);
      expect(Array.from(decodeBase64Url(expected))).toEqual(Array.from(bytes));
    }
  });

  it('round-trips 32-byte keys', () => {
    const key = new Uint8Array(32).map((_, i) => (i * 7 + 3) & 0xff);
    expect(Array.from(decodeBase64Url(encodeBase64Url(key)))).toEqual(Array.from(key));
  });

  it('accepts padded and standard-base64 spellings on decode', () => {
    // "AA==" (padded) and the url form "AA" both decode to a single zero byte.
    expect(Array.from(decodeBase64Url('AA=='))).toEqual([0x00]);
    expect(Array.from(decodeBase64Url('__8'))).toEqual([0xff, 0xff]);
    expect(Array.from(decodeBase64Url('//8='))).toEqual([0xff, 0xff]);
  });

  it('rejects invalid characters and lengths', () => {
    expect(() => decodeBase64Url('!!!!')).toThrow();
    expect(() => decodeBase64Url('A')).toThrow();
  });

  it('validates unpadded base64url spelling', () => {
    expect(isValidUnpaddedBase64Url('abcABC-_09')).toBe(true);
    expect(isValidUnpaddedBase64Url('')).toBe(false);
    expect(isValidUnpaddedBase64Url('AA==')).toBe(false);
    expect(isValidUnpaddedBase64Url('a+b/c')).toBe(false);
  });
});
