/** @jest-environment node */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { beforeAll, describe, expect, it } from '@jest/globals';

import {
  buildPushSealVector,
  serializePushSealVector,
} from '../../../scripts/pushSealVectorBuilder';
import { loadSodium } from '../../../scripts/loadSodium';
import { decodeBase64Url, encodeBase64Url } from '../base64url';
import { derivePushKey, sealPush, unsealPush } from '../pushCrypto';
import type { SodiumLike } from '../sodium';

// companion/wire/vectors/crypto/push-seal.json — the phone's expectation of the
// push-seal scheme. If the Mac has pinned its own, this test asserts interop
// against it; otherwise it writes/verifies the phone-side vector.
const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/push-seal.json');
const GENERATE = process.env.GENERATE_VECTORS === '1';
const decoder = new TextDecoder();

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

describe('push-seal offline crypto', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  it('derives the same offline key from both sides (ECDH symmetry)', () => {
    const macSeed = sodium.randomBytes(32);
    const phoneSeed = sodium.randomBytes(32);
    const macPub = sodium.signSeedKeypair(macSeed).publicKey;
    const phonePub = sodium.signSeedKeypair(phoneSeed).publicKey;

    // Phone: X25519(phonePriv, macPub).
    const phoneKey = derivePushKey(sodium, {
      macIdentityPublicKey: macPub,
      phoneIdentitySeed: phoneSeed,
    });
    // Mac's mirror: X25519(macPriv, phonePub) via the same helper, roles swapped.
    const macKey = derivePushKey(sodium, {
      macIdentityPublicKey: phonePub,
      phoneIdentitySeed: macSeed,
    });
    expect(encodeBase64Url(phoneKey)).toBe(encodeBase64Url(macKey));
  });

  it('round-trips a sealed wake payload', () => {
    const macSeed = sodium.randomBytes(32);
    const phoneSeed = sodium.randomBytes(32);
    const macPub = sodium.signSeedKeypair(macSeed).publicKey;

    const key = derivePushKey(sodium, {
      macIdentityPublicKey: macPub,
      phoneIdentitySeed: phoneSeed,
    });
    const nonce = sodium.randomBytes(12);
    const plaintext = utf8('{"paneId":"pane-1","title":"hi","body":"there"}');
    const sealed = sealPush(sodium, key, nonce, plaintext);

    expect(decoder.decode(unsealPush(sodium, key, sealed))).toBe(decoder.decode(plaintext));
  });

  it('rejects a tampered ciphertext', () => {
    const macSeed = sodium.randomBytes(32);
    const phoneSeed = sodium.randomBytes(32);
    const macPub = sodium.signSeedKeypair(macSeed).publicKey;
    const key = derivePushKey(sodium, { macIdentityPublicKey: macPub, phoneIdentitySeed: phoneSeed });
    const sealed = sealPush(sodium, key, sodium.randomBytes(12), utf8('secret'));
    sealed[sealed.length - 1] ^= 0xff; // flip a tag byte
    expect(() => unsealPush(sodium, key, sealed)).toThrow();
  });

  it('rejects a wrong-key open', () => {
    const macPub = sodium.signSeedKeypair(sodium.randomBytes(32)).publicKey;
    const key = derivePushKey(sodium, {
      macIdentityPublicKey: macPub,
      phoneIdentitySeed: sodium.randomBytes(32),
    });
    const sealed = sealPush(sodium, key, sodium.randomBytes(12), utf8('secret'));
    const wrongKey = derivePushKey(sodium, {
      macIdentityPublicKey: macPub,
      phoneIdentitySeed: sodium.randomBytes(32),
    });
    expect(() => unsealPush(sodium, wrongKey, sealed)).toThrow();
  });

  it('regeneration is deterministic and matches the checked-in vector', () => {
    const serialized = serializePushSealVector(buildPushSealVector(sodium));
    if (GENERATE) {
      mkdirSync(dirname(VECTOR_PATH), { recursive: true });
      writeFileSync(VECTOR_PATH, serialized);
    }
    expect(existsSync(VECTOR_PATH)).toBe(true);
    expect(readFileSync(VECTOR_PATH, 'utf8')).toBe(serialized);
  });

  it('the checked-in vector unseals to its stated plaintext with its derived key', () => {
    const v = JSON.parse(readFileSync(VECTOR_PATH, 'utf8')) as {
      keys: { macIdentityPriv: string; phoneIdentityPriv: string };
      derivedPublicKeys: { macIdentityPub: string };
      expected: { pushKey: string; sealedSample: { plaintext: string; sealed: string } };
    };
    const key = derivePushKey(sodium, {
      macIdentityPublicKey: decodeBase64Url(v.derivedPublicKeys.macIdentityPub),
      phoneIdentitySeed: decodeBase64Url(v.keys.phoneIdentityPriv),
    });
    expect(encodeBase64Url(key)).toBe(v.expected.pushKey);
    const opened = unsealPush(sodium, key, decodeBase64Url(v.expected.sealedSample.sealed));
    expect(decoder.decode(opened)).toBe(v.expected.sealedSample.plaintext);
  });
});
