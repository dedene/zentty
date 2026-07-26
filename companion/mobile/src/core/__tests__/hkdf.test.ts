/** @jest-environment node */
import { createHash, createHmac, hkdfSync } from 'node:crypto';
import { describe, expect, it } from '@jest/globals';

import { hkdfSha256, hmacSha256, sha256 } from '../hkdf';

function hex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('hex');
}

function fromHex(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, 'hex'));
}

describe('sha256', () => {
  it('matches the RFC 6234 "abc" vector', () => {
    expect(hex(sha256(new TextEncoder().encode('abc')))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  it('hashes the empty string', () => {
    expect(hex(sha256(new Uint8Array(0)))).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
  });

  it('matches Node crypto across multi-block lengths', () => {
    for (const len of [0, 1, 55, 56, 63, 64, 65, 200, 1000]) {
      const data = new Uint8Array(len).map((_, i) => (i * 31 + 7) & 0xff);
      const expected = createHash('sha256').update(Buffer.from(data)).digest('hex');
      expect(hex(sha256(data))).toBe(expected);
    }
  });
});

describe('hmacSha256', () => {
  it('matches the RFC 4231 test case 2', () => {
    const key = new TextEncoder().encode('Jefe');
    const data = new TextEncoder().encode('what do ya want for nothing?');
    expect(hex(hmacSha256(key, data))).toBe(
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    );
  });

  it('matches Node crypto with a long key (>64 bytes triggers key hashing)', () => {
    const key = new Uint8Array(100).map((_, i) => (i * 13) & 0xff);
    const msg = new Uint8Array(50).map((_, i) => (i * 5) & 0xff);
    const expected = createHmac('sha256', Buffer.from(key)).update(Buffer.from(msg)).digest('hex');
    expect(hex(hmacSha256(key, msg))).toBe(expected);
  });
});

describe('hkdfSha256', () => {
  it('matches RFC 5869 Appendix A.1', () => {
    const ikm = fromHex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b');
    const salt = fromHex('000102030405060708090a0b0c');
    const info = fromHex('f0f1f2f3f4f5f6f7f8f9');
    const okm = hkdfSha256(ikm, salt, info, 42);
    expect(hex(okm)).toBe(
      '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865',
    );
  });

  it('matches Node hkdfSync over the companion-shaped inputs (long salt, 32-byte OKM)', () => {
    const ikm = new Uint8Array(32).map((_, i) => (i + 1) & 0xff);
    const salt = new Uint8Array(157).map((_, i) => (i * 3) & 0xff); // ~transcript length
    const info = new TextEncoder().encode('zentty-companion/v1/mac->phone');
    const mine = hkdfSha256(ikm, salt, info, 32);
    const nodeOut = new Uint8Array(hkdfSync('sha256', ikm, salt, info, 32));
    expect(hex(mine)).toBe(hex(nodeOut));
  });
});
