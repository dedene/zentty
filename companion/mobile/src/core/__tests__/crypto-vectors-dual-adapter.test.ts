/** @jest-environment node */
/**
 * Proves the @stablelib RUNTIME adapter (src/runtime/sodium.ts) — the one that
 * actually ships on device — derives the identical interop vector as both the
 * libsodium-wrappers TEST adapter and the checked-in Swift/CryptoKit pin.
 *
 * Two independent implementations (@stablelib pure-TS vs libsodium's C/WASM)
 * agreeing byte-for-byte with the Mac pin is the cross-check that guards X25519
 * clamping, Ed25519 seed→signature formats, ChaCha20-Poly1305-IETF, and the HKDF
 * nonce/counter layout against silent drift.
 */
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { resolve } from 'node:path';
import { beforeAll, describe, expect, it } from '@jest/globals';

import { buildSessionCryptoVector, serializeVector } from '../../../scripts/cryptoVectorBuilder';
import { loadSodium } from '../../../scripts/loadSodium';
import { createStablelibSodium } from '../../runtime/sodium';
import { decodeBase64Url } from '../base64url';
import { CompanionSessionCrypto, handshakeTranscript, MAC_TO_PHONE_SALT } from '../crypto';
import type { SodiumLike } from '../sodium';

const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/session-crypto.json');

/** A real CSPRNG for the adapter's randomBytes; unused by the fixed-key vector. */
const nodeRandomBytes = (length: number): Uint8Array => {
  const out = new Uint8Array(length);
  webcrypto.getRandomValues(out);
  return out;
};

describe('session-crypto vector through the @stablelib runtime adapter', () => {
  const stablelib: SodiumLike = createStablelibSodium(nodeRandomBytes);
  let libsodium: SodiumLike;
  beforeAll(async () => {
    libsodium = await loadSodium();
  });

  it('reproduces the checked-in vector byte-for-byte', () => {
    expect(serializeVector(buildSessionCryptoVector(stablelib))).toBe(
      readFileSync(VECTOR_PATH, 'utf8'),
    );
  });

  it('agrees byte-for-byte with the libsodium-wrappers adapter', () => {
    expect(serializeVector(buildSessionCryptoVector(stablelib))).toBe(
      serializeVector(buildSessionCryptoVector(libsodium)),
    );
  });

  it('verifies signatures and opens the sealed sample', () => {
    const v = buildSessionCryptoVector(stablelib);
    const macIdentityPub = decodeBase64Url(v.derivedPublicKeys.macIdentityPub);
    const phoneIdentityPub = decodeBase64Url(v.derivedPublicKeys.phoneIdentityPub);
    const macEphPub = decodeBase64Url(v.derivedPublicKeys.macEphPub);
    const phoneEphPub = decodeBase64Url(v.derivedPublicKeys.phoneEphPub);
    const transcript = handshakeTranscript({
      role: 'mac',
      localIdentityPublicKey: macIdentityPub,
      localEphemeralPublicKey: macEphPub,
      peerIdentityPublicKey: phoneIdentityPub,
      peerEphemeralPublicKey: phoneEphPub,
    });

    expect(
      stablelib.signVerifyDetached(
        decodeBase64Url(v.expected.handshakeSigMac),
        transcript,
        macIdentityPub,
      ),
    ).toBe(true);
    expect(
      stablelib.signVerifyDetached(
        decodeBase64Url(v.expected.handshakeSigPhone),
        transcript,
        phoneIdentityPub,
      ),
    ).toBe(true);

    // A signature produced by libsodium must verify under @stablelib and vice
    // versa (cross-implementation Ed25519 interop, the same guarantee we need
    // against CryptoKit on the Mac).
    expect(
      libsodium.signVerifyDetached(
        decodeBase64Url(v.expected.handshakeSigMac),
        transcript,
        macIdentityPub,
      ),
    ).toBe(true);

    const phoneReceive = new CompanionSessionCrypto(stablelib, {
      sendKey: decodeBase64Url(v.expected.sendKeyPhoneToMac),
      sendSalt: MAC_TO_PHONE_SALT,
      receiveKey: decodeBase64Url(v.expected.sendKeyMacToPhone),
      receiveSalt: MAC_TO_PHONE_SALT,
    });
    const opened = phoneReceive.open(decodeBase64Url(v.expected.sealedSample.ciphertext));
    expect(new TextDecoder().decode(opened)).toBe(v.expected.sealedSample.plaintext);
  });
});
