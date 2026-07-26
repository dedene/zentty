/** @jest-environment node */
/**
 * Locks the NSE key-material blob (src/core/pushKeyMaterial.ts) to the contract
 * the iOS Notification Service Extension parses natively in
 * plugins/notification-service/NotificationService.swift (`KeyMaterial.load`):
 *
 *   - top-level keys are exactly `phoneX25519Priv` and `macX25519Pub`,
 *   - every value is unpadded base64url of a raw 32-byte X25519 key,
 *   - `macX25519Pub` is keyed by the Mac's `macDeviceId` (the string the Mac
 *     puts in the wake envelope).
 *
 * The interop pin is the checked-in push-seal vector: the material built here,
 * fed through the exact steps the NSE performs (X25519 ECDH + HKDF-SHA256 with
 * salt "zentty-push/v1" / info "zentty-push"), must reproduce the vector's
 * pushKey — proving the mirrored bytes let the NSE derive the Mac's seal key.
 */
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { resolve } from 'node:path';
import { describe, expect, it } from '@jest/globals';

import { createStablelibSodium } from '../../runtime/sodium';
import { decodeBase64Url, encodeBase64Url } from '../base64url';
import { hkdfSha256 } from '../hkdf';
import { buildPushKeyMaterial } from '../pushKeyMaterial';
import type { PairedMac } from '../storage';

const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/push-seal.json');

const nodeRandomBytes = (length: number): Uint8Array => {
  const out = new Uint8Array(length);
  webcrypto.getRandomValues(out);
  return out;
};

const sodium = createStablelibSodium(nodeRandomBytes);
const utf8 = new TextEncoder();

const vector = JSON.parse(readFileSync(VECTOR_PATH, 'utf8')) as {
  keys: { phoneIdentityPriv: string };
  derivedPublicKeys: { macIdentityPub: string };
  expected: { pushKey: string };
};

/** A pairing whose Mac is the vector's Mac identity. */
function vectorMac(): PairedMac {
  return {
    macDeviceId: vector.derivedPublicKeys.macIdentityPub,
    macPubKey: vector.derivedPublicKeys.macIdentityPub,
    macName: 'Vector Mac',
    pairedAt: 0,
  };
}

describe('buildPushKeyMaterial', () => {
  const material = buildPushKeyMaterial(sodium, {
    phoneIdentitySeed: decodeBase64Url(vector.keys.phoneIdentityPriv),
    macs: [vectorMac()],
  });

  it('uses exactly the JSON keys the NSE parses', () => {
    expect(Object.keys(material).sort()).toEqual(['macX25519Pub', 'phoneX25519Priv']);
    expect(Object.keys(material.macX25519Pub)).toEqual([vector.derivedPublicKeys.macIdentityPub]);
  });

  it('encodes raw 32-byte X25519 keys as unpadded base64url', () => {
    const values = [material.phoneX25519Priv, ...Object.values(material.macX25519Pub)];
    for (const value of values) {
      // The NSE's base64url decoder maps -_ → +/ and re-adds padding; the JS
      // encoder must therefore emit the unpadded URL-safe alphabet.
      expect(value).toMatch(/^[A-Za-z0-9\-_]+$/);
      expect(decodeBase64Url(value)).toHaveLength(32);
    }
  });

  it('mirrors the same converted keys the in-app derivation uses', () => {
    const phoneKeypair = sodium.signSeedKeypair(decodeBase64Url(vector.keys.phoneIdentityPriv));
    expect(material.phoneX25519Priv).toBe(
      encodeBase64Url(sodium.ed25519SecretKeyToX25519(phoneKeypair.secretKey)),
    );
    expect(material.macX25519Pub[vector.derivedPublicKeys.macIdentityPub]).toBe(
      encodeBase64Url(
        sodium.ed25519PublicKeyToX25519(decodeBase64Url(vector.derivedPublicKeys.macIdentityPub)),
      ),
    );
  });

  it('reproduces the push-seal vector pushKey through the NSE derivation steps', () => {
    // Exactly what NotificationService.swift does with the mirrored blob:
    // shared = X25519(phoneX25519Priv, macX25519Pub), then HKDF-SHA256 with the
    // scheme's salt/info. This must land on the Mac's seal key.
    const shared = sodium.scalarMult(
      decodeBase64Url(material.phoneX25519Priv),
      decodeBase64Url(material.macX25519Pub[vector.derivedPublicKeys.macIdentityPub]),
    );
    const key = hkdfSha256(shared, utf8.encode('zentty-push/v1'), utf8.encode('zentty-push'), 32);
    expect(encodeBase64Url(key)).toBe(vector.expected.pushKey);
  });

  it('builds an empty mac map when no Macs are paired', () => {
    const empty = buildPushKeyMaterial(sodium, {
      phoneIdentitySeed: decodeBase64Url(vector.keys.phoneIdentityPriv),
      macs: [],
    });
    expect(empty.macX25519Pub).toEqual({});
  });
});
