/** @jest-environment node */
import { beforeAll, describe, expect, it } from '@jest/globals';

import { loadSodium } from '../../../scripts/loadSodium';
import { encodeBase64Url } from '../base64url';
import { derivePushKey, sealPush } from '../pushCrypto';
import {
  parsePushWakeContent,
  parsePushWakeEnvelope,
  resolvePushDeepLink,
} from '../pushWake';
import type { SodiumLike } from '../sodium';

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

describe('parsePushWakeEnvelope', () => {
  it('reads a namespaced zentty envelope', () => {
    expect(
      parsePushWakeEnvelope({ zentty: { v: 1, macDeviceId: 'mac-1', sealed: 'AAAA' } }),
    ).toEqual({ v: 1, macDeviceId: 'mac-1', sealed: 'AAAA' });
  });

  it('reads a flat envelope and defaults v', () => {
    expect(parsePushWakeEnvelope({ macDeviceId: 'mac-1', sealed: 'AAAA' })).toEqual({
      v: 1,
      macDeviceId: 'mac-1',
      sealed: 'AAAA',
    });
  });

  it('ignores non-wake / malformed payloads', () => {
    expect(parsePushWakeEnvelope(undefined)).toBeUndefined();
    expect(parsePushWakeEnvelope({})).toBeUndefined();
    expect(parsePushWakeEnvelope({ macDeviceId: 'mac-1' })).toBeUndefined();
    expect(parsePushWakeEnvelope({ sealed: 'AAAA' })).toBeUndefined();
    expect(parsePushWakeEnvelope('nope')).toBeUndefined();
  });
});

describe('parsePushWakeContent', () => {
  it('parses full content', () => {
    expect(
      parsePushWakeContent(utf8('{"paneId":"p1","worklaneId":"w1","title":"t","body":"b"}')),
    ).toEqual({ paneId: 'p1', worklaneId: 'w1', title: 't', body: 'b' });
  });

  it('throws without a paneId', () => {
    expect(() => parsePushWakeContent(utf8('{"title":"t"}'))).toThrow();
  });
});

describe('resolvePushDeepLink', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  function sealedFor(macSeed: Uint8Array, phonePub: Uint8Array, content: object): string {
    // The Mac seals to the phone: X25519(macPriv, phonePub).
    const key = derivePushKey(sodium, {
      macIdentityPublicKey: phonePub,
      phoneIdentitySeed: macSeed,
    });
    const sealed = sealPush(sodium, key, sodium.randomBytes(12), utf8(JSON.stringify(content)));
    return encodeBase64Url(sealed);
  }

  it('decrypts a wake and routes to the pane', () => {
    const macSeed = sodium.randomBytes(32);
    const phoneSeed = sodium.randomBytes(32);
    const macPub = sodium.signSeedKeypair(macSeed).publicKey;
    const phonePub = sodium.signSeedKeypair(phoneSeed).publicKey;
    const macDeviceId = encodeBase64Url(macPub);

    const sealed = sealedFor(macSeed, phonePub, {
      paneId: 'pane-42',
      title: 'Approval needed',
      body: 'Delete node_modules?',
    });

    const link = resolvePushDeepLink(sodium, {
      data: { zentty: { v: 1, macDeviceId, sealed } },
      phoneIdentitySeed: phoneSeed,
      macPublicKeyFor: (id) => (id === macDeviceId ? macDeviceId : undefined),
    });

    expect(link).toBeDefined();
    expect(link?.macDeviceId).toBe(macDeviceId);
    expect(link?.paneId).toBe('pane-42');
    expect(link?.content.title).toBe('Approval needed');
  });

  it('returns undefined for an unknown Mac', () => {
    const link = resolvePushDeepLink(sodium, {
      data: { macDeviceId: 'unknown', sealed: 'AAAAAAAA' },
      phoneIdentitySeed: sodium.randomBytes(32),
      macPublicKeyFor: () => undefined,
    });
    expect(link).toBeUndefined();
  });

  it('returns undefined for a tampered blob rather than throwing', () => {
    const macSeed = sodium.randomBytes(32);
    const phoneSeed = sodium.randomBytes(32);
    const macPub = sodium.signSeedKeypair(macSeed).publicKey;
    const phonePub = sodium.signSeedKeypair(phoneSeed).publicKey;
    const macDeviceId = encodeBase64Url(macPub);
    const sealed = sealedFor(macSeed, phonePub, { paneId: 'x' });
    // Corrupt the base64url payload.
    const tampered = `${sealed.slice(0, -2)}AA`;

    const link = resolvePushDeepLink(sodium, {
      data: { macDeviceId, sealed: tampered },
      phoneIdentitySeed: phoneSeed,
      macPublicKeyFor: () => macDeviceId,
    });
    expect(link).toBeUndefined();
  });
});
