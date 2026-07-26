/** @jest-environment node */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { beforeAll, describe, expect, it } from '@jest/globals';

import { buildSessionCryptoVector, serializeVector } from '../../../scripts/cryptoVectorBuilder';
import { loadSodium } from '../../../scripts/loadSodium';
import { decodeBase64Url } from '../base64url';
import { CompanionSessionCrypto, handshakeTranscript, MAC_TO_PHONE_SALT } from '../crypto';
import type { SodiumLike } from '../sodium';

// companion/wire/vectors/crypto/session-crypto.json, checked in and pinned by the
// Swift conformance suite.
const VECTOR_PATH = resolve(__dirname, '../../../../wire/vectors/crypto/session-crypto.json');
const GENERATE = process.env.GENERATE_VECTORS === '1';

describe('session-crypto interop vector', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  it('regeneration is deterministic and matches the checked-in file', () => {
    const serialized = serializeVector(buildSessionCryptoVector(sodium));
    if (GENERATE) {
      mkdirSync(dirname(VECTOR_PATH), { recursive: true });
      writeFileSync(VECTOR_PATH, serialized);
    }
    expect(existsSync(VECTOR_PATH)).toBe(true);
    // The exact "regenerate must be a no-op" contract the Swift pin also relies on.
    expect(readFileSync(VECTOR_PATH, 'utf8')).toBe(serialized);
  });

  it('is internally consistent: signatures verify and the sealed sample opens', () => {
    const v = buildSessionCryptoVector(sodium);

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
      sodium.signVerifyDetached(
        decodeBase64Url(v.expected.handshakeSigMac),
        transcript,
        macIdentityPub,
      ),
    ).toBe(true);
    expect(
      sodium.signVerifyDetached(
        decodeBase64Url(v.expected.handshakeSigPhone),
        transcript,
        phoneIdentityPub,
      ),
    ).toBe(true);

    // Open the mac->phone sealed sample as a phone-role receiver would.
    const phoneReceive = new CompanionSessionCrypto(sodium, {
      sendKey: decodeBase64Url(v.expected.sendKeyPhoneToMac),
      sendSalt: MAC_TO_PHONE_SALT, // send side unused here
      receiveKey: decodeBase64Url(v.expected.sendKeyMacToPhone),
      receiveSalt: MAC_TO_PHONE_SALT,
    });
    const opened = phoneReceive.open(decodeBase64Url(v.expected.sealedSample.ciphertext));
    expect(new TextDecoder().decode(opened)).toBe(v.expected.sealedSample.plaintext);
  });
});
