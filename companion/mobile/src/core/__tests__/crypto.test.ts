/** @jest-environment node */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeAll, describe, expect, it } from '@jest/globals';

import { loadSodium } from '../../../scripts/loadSodium';
import { decodeBase64Url, encodeBase64Url } from '../base64url';
import {
  CompanionCryptoError,
  CompanionSessionCrypto,
  establishSession,
  localHandshakeSignature,
} from '../crypto';
import type { SodiumLike } from '../sodium';

const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/session-crypto.json');

interface Party {
  identitySeed: Uint8Array;
  identityPub: Uint8Array;
  ephPriv: Uint8Array;
  ephPub: Uint8Array;
}

function makeParty(sodium: SodiumLike, seed?: Uint8Array, eph?: Uint8Array): Party {
  const identitySeed = seed ?? sodium.randomBytes(32);
  const ephPriv = eph ?? sodium.randomBytes(32);
  return {
    identitySeed,
    identityPub: sodium.signSeedKeypair(identitySeed).publicKey,
    ephPriv,
    ephPub: sodium.scalarMultBase(ephPriv),
  };
}

/** Establish both ends of a session and return their crypto channels. */
function establishPair(
  sodium: SodiumLike,
  mac: Party,
  phone: Party,
): { mac: CompanionSessionCrypto; phone: CompanionSessionCrypto } {
  const macSig = localHandshakeSignature(sodium, {
    role: 'mac',
    localIdentitySeed: mac.identitySeed,
    localEphemeralPublicKey: mac.ephPub,
    peerIdentityPublicKey: phone.identityPub,
    peerEphemeralPublicKey: phone.ephPub,
  });
  const phoneSig = localHandshakeSignature(sodium, {
    role: 'phone',
    localIdentitySeed: phone.identitySeed,
    localEphemeralPublicKey: phone.ephPub,
    peerIdentityPublicKey: mac.identityPub,
    peerEphemeralPublicKey: mac.ephPub,
  });
  const macCrypto = establishSession(sodium, {
    role: 'mac',
    localIdentitySeed: mac.identitySeed,
    localEphemeralPrivateKey: mac.ephPriv,
    localEphemeralPublicKey: mac.ephPub,
    peerIdentityPublicKey: phone.identityPub,
    peerEphemeralPublicKey: phone.ephPub,
    peerSignature: phoneSig,
  });
  const phoneCrypto = establishSession(sodium, {
    role: 'phone',
    localIdentitySeed: phone.identitySeed,
    localEphemeralPrivateKey: phone.ephPriv,
    localEphemeralPublicKey: phone.ephPub,
    peerIdentityPublicKey: mac.identityPub,
    peerEphemeralPublicKey: mac.ephPub,
    peerSignature: macSig,
  });
  return { mac: macCrypto, phone: phoneCrypto };
}

describe('CompanionHandshake + CompanionSessionCrypto', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  it('derives agreeing directional keys and round-trips both directions', () => {
    const { mac, phone } = establishPair(sodium, makeParty(sodium), makeParty(sodium));
    const enc = new TextEncoder();

    const m2p = mac.seal(enc.encode('hello from mac'));
    expect(new TextDecoder().decode(phone.open(m2p))).toBe('hello from mac');

    const p2m = phone.seal(enc.encode('reply from phone'));
    expect(new TextDecoder().decode(mac.open(p2m))).toBe('reply from phone');
  });

  it('advances the counter so successive frames differ and both open in order', () => {
    const { mac, phone } = establishPair(sodium, makeParty(sodium), makeParty(sodium));
    const a = mac.seal(new Uint8Array([1]));
    const b = mac.seal(new Uint8Array([1]));
    expect(encodeBase64Url(a)).not.toBe(encodeBase64Url(b));
    expect(Array.from(phone.open(a))).toEqual([1]);
    expect(Array.from(phone.open(b))).toEqual([1]);
  });

  it('rejects a replayed / non-advancing counter', () => {
    const { mac, phone } = establishPair(sodium, makeParty(sodium), makeParty(sodium));
    const frame = mac.seal(new Uint8Array([9]));
    phone.open(frame);
    expect(() => phone.open(frame)).toThrow(CompanionCryptoError);
    try {
      phone.open(frame);
    } catch (error) {
      expect((error as CompanionCryptoError).code).toBe('replayDetected');
    }
  });

  it('rejects a frame shorter than counter + tag', () => {
    const { phone } = establishPair(sodium, makeParty(sodium), makeParty(sodium));
    try {
      phone.open(new Uint8Array(10));
      throw new Error('expected throw');
    } catch (error) {
      expect((error as CompanionCryptoError).code).toBe('malformedSealedFrame');
    }
  });

  it('rejects a tampered ciphertext (AEAD auth failure)', () => {
    const { mac, phone } = establishPair(sodium, makeParty(sodium), makeParty(sodium));
    const frame = mac.seal(new Uint8Array([1, 2, 3]));
    frame[frame.length - 1] ^= 0xff; // flip a tag byte
    expect(() => phone.open(frame)).toThrow();
  });

  it('fails establishment on a bad peer signature', () => {
    const mac = makeParty(sodium);
    const phone = makeParty(sodium);
    const badSig = sodium.randomBytes(64);
    try {
      establishSession(sodium, {
        role: 'phone',
        localIdentitySeed: phone.identitySeed,
        localEphemeralPrivateKey: phone.ephPriv,
        localEphemeralPublicKey: phone.ephPub,
        peerIdentityPublicKey: mac.identityPub,
        peerEphemeralPublicKey: mac.ephPub,
        peerSignature: badSig,
      });
      throw new Error('expected throw');
    } catch (error) {
      expect((error as CompanionCryptoError).code).toBe('invalidHandshakeSignature');
    }
  });

  it('matches the checked-in interop vector byte-for-byte', () => {
    const v = JSON.parse(readFileSync(VECTOR_PATH, 'utf8')) as {
      keys: Record<string, string>;
      expected: {
        sendKeyMacToPhone: string;
        sendKeyPhoneToMac: string;
        sealedSample: { plaintext: string; ciphertext: string };
      };
    };

    const mac = makeParty(
      sodium,
      decodeBase64Url(v.keys.macIdentityPriv),
      decodeBase64Url(v.keys.macEphPriv),
    );
    const phone = makeParty(
      sodium,
      decodeBase64Url(v.keys.phoneIdentityPriv),
      decodeBase64Url(v.keys.phoneEphPriv),
    );
    const { phone: phoneCrypto } = establishPair(sodium, mac, phone);

    // The vector's mac->phone sealed sample opens on the phone side to the exact
    // documented plaintext — the same bytes the Swift/CryptoKit pin must produce.
    const opened = phoneCrypto.open(decodeBase64Url(v.expected.sealedSample.ciphertext));
    expect(new TextDecoder().decode(opened)).toBe(v.expected.sealedSample.plaintext);
  });
});
