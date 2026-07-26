/** @jest-environment node */
/**
 * Locks the Ed25519→X25519 identity conversion — the one primitive the offline
 * push-seal key derivation leans on — to libsodium semantics on BOTH adapters the
 * app can run:
 *
 *   - the @stablelib RUNTIME adapter (src/runtime/sodium.ts) that ships on device,
 *   - the libsodium-wrappers TEST adapter (scripts/loadSodium.ts).
 *
 * The reference bytes are the exact PyNaCl (libsodium `crypto_sign_ed25519_*_to_
 * curve25519`) vectors pinned on the Mac side in
 * ZenttyLogicTests/CompanionPushTests.swift (`conversionVectors`). If either
 * adapter drifts from these, the phone would derive a different shared secret than
 * the Mac and on-device push decryption would silently fail — so we assert
 * byte-equality here, and again through the full push-seal interop vector.
 */
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { resolve } from 'node:path';
import { beforeAll, describe, expect, it } from '@jest/globals';

import {
  buildPushSealVector,
  serializePushSealVector,
} from '../../../scripts/pushSealVectorBuilder';
import { loadSodium } from '../../../scripts/loadSodium';
import { createStablelibSodium } from '../../runtime/sodium';
import { decodeBase64Url, encodeBase64Url } from '../base64url';
import { derivePushKey, unsealPush } from '../pushCrypto';
import type { SodiumLike } from '../sodium';

const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/push-seal.json');

/** A real CSPRNG for the adapter's randomBytes; unused by the fixed-key vectors. */
const nodeRandomBytes = (length: number): Uint8Array => {
  const out = new Uint8Array(length);
  webcrypto.getRandomValues(out);
  return out;
};

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Byte-for-byte the `conversionVectors` in ZenttyLogicTests/CompanionPushTests.swift,
// which are PyNaCl / libsodium outputs. seed → ed25519 pub → curve25519 pub/priv.
const CONVERSION_VECTORS = [
  {
    seedHex: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    edPubHex: '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8',
    curvePubHex: '4701d08488451f545a409fb58ae3e58581ca40ac3f7f114698cd71deac73ca01',
    curvePrivHex: '3894eea49c580aef816935762be049559d6d1440dede12e6a125f1841fff8e6f',
  },
  {
    seedHex: '030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc',
    edPubHex: '755c4cb9256ca7cdc4acfdc6cfeeda849017e5b9f9514e99191bd67e0b0d4276',
    curvePubHex: 'be2b8b75b369b8f459b8b153799bc5ab07a2f8feba04c11cc843d19fe55ae25c',
    curvePrivHex: 'c0902ef600c188f0a9b0d32d5e78edf886d61887e698a81aab084c8f86dbfe6f',
  },
  {
    seedHex: '056acf3499fe63c82d92f75cc1268bf055ba1f84e94eb3187de247ac1176db40',
    edPubHex: '13c1d03f8b954c931ff0f483522ed13c7cb8297fc8253ab986093e3c21831a5d',
    curvePubHex: '2d9f75bdf18f5ce48ade37de11a1d7705af1616b186f8ed50cf155fc78566212',
    curvePrivHex: '506a8ba1a795c74f89c6d7c0ddf9c435eb789c13a0b4b21e9ab2d60dd21a8a4e',
  },
] as const;

describe('Ed25519→X25519 conversion matches libsodium (PyNaCl) on both adapters', () => {
  const stablelib: SodiumLike = createStablelibSodium(nodeRandomBytes);
  let libsodium: SodiumLike;
  beforeAll(async () => {
    libsodium = await loadSodium();
  });

  const adapters = (): Array<[string, SodiumLike]> => [
    ['@stablelib runtime', stablelib],
    ['libsodium-wrappers', libsodium],
  ];

  it.each(CONVERSION_VECTORS)(
    'pk_to_curve25519 for seed $seedHex',
    ({ seedHex, edPubHex, curvePubHex }) => {
      for (const [name, sodium] of adapters()) {
        // Sanity: the seed maps to the expected Ed25519 public key.
        const derivedPub = sodium.signSeedKeypair(fromHex(seedHex)).publicKey;
        expect(`${name}:${toHex(derivedPub)}`).toBe(`${name}:${edPubHex}`);
        // pk_to_curve25519 lands on the libsodium curve public key.
        const curvePub = sodium.ed25519PublicKeyToX25519(fromHex(edPubHex));
        expect(`${name}:${toHex(curvePub)}`).toBe(`${name}:${curvePubHex}`);
      }
    },
  );

  it.each(CONVERSION_VECTORS)(
    'sk_to_curve25519 for seed $seedHex',
    ({ seedHex, curvePrivHex }) => {
      for (const [name, sodium] of adapters()) {
        const secretKey = sodium.signSeedKeypair(fromHex(seedHex)).secretKey;
        const curvePriv = sodium.ed25519SecretKeyToX25519(secretKey);
        expect(`${name}:${toHex(curvePriv)}`).toBe(`${name}:${curvePrivHex}`);
      }
    },
  );
});

describe('push-seal vector through the @stablelib runtime adapter', () => {
  const stablelib: SodiumLike = createStablelibSodium(nodeRandomBytes);
  let libsodium: SodiumLike;
  beforeAll(async () => {
    libsodium = await loadSodium();
  });

  it('reproduces the checked-in vector byte-for-byte', () => {
    expect(serializePushSealVector(buildPushSealVector(stablelib))).toBe(
      readFileSync(VECTOR_PATH, 'utf8'),
    );
  });

  it('agrees byte-for-byte with the libsodium-wrappers adapter', () => {
    expect(serializePushSealVector(buildPushSealVector(stablelib))).toBe(
      serializePushSealVector(buildPushSealVector(libsodium)),
    );
  });

  it('derives the vector pushKey and opens its sealed sample', () => {
    const v = JSON.parse(readFileSync(VECTOR_PATH, 'utf8')) as {
      keys: { phoneIdentityPriv: string };
      derivedPublicKeys: { macIdentityPub: string };
      expected: { pushKey: string; sealedSample: { plaintext: string; sealed: string } };
    };
    const key = derivePushKey(stablelib, {
      macIdentityPublicKey: decodeBase64Url(v.derivedPublicKeys.macIdentityPub),
      phoneIdentitySeed: decodeBase64Url(v.keys.phoneIdentityPriv),
    });
    expect(encodeBase64Url(key)).toBe(v.expected.pushKey);
    const opened = unsealPush(stablelib, key, decodeBase64Url(v.expected.sealedSample.sealed));
    expect(new TextDecoder().decode(opened)).toBe(v.expected.sealedSample.plaintext);
  });
});
