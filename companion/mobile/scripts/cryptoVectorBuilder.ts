/**
 * Deterministic builder for the session-crypto interop vector, shared by the
 * generator script and the conformance test. All inputs are FIXED, test-only
 * keys, so re-running produces byte-identical output (the "regenerate is a no-op"
 * contract). The Swift pin stage loads the same JSON and asserts CryptoKit
 * derives the identical directional keys, signatures, and sealed frame.
 *
 * WARNING: the private keys below are throwaway test vectors. They must never be
 * used for a real device identity or session.
 */

import { encodeBase64Url } from '../src/core/base64url';
import {
  MAC_TO_PHONE_INFO,
  MAC_TO_PHONE_SALT,
  PHONE_TO_MAC_INFO,
  handshakeTranscript,
  localHandshakeSignature,
  sealFrameAt,
  utf8Bytes,
  HANDSHAKE_LABEL,
} from '../src/core/crypto';
import { hkdfSha256 } from '../src/core/hkdf';
import type { SodiumLike } from '../src/core/sodium';

// Fixed test-only private keys (32-byte raw). Ed25519 seeds for the identities,
// X25519 scalars for the ephemerals.
const MAC_IDENTITY_PRIV_HEX =
  '1e4004aa516193bc955e8c716eee47e60294613dea353581f25051cc34aac92c';
const PHONE_IDENTITY_PRIV_HEX =
  'c4969bf09cdcc7f7fbdee3753c54d74349dd7082cafb424bab88f155ba4096f7';
const MAC_EPH_PRIV_HEX =
  'ced6f877c21002ed457f55cdce52297baa62befeffada4548b0d8d5949e5dbea';
const PHONE_EPH_PRIV_HEX =
  'dc36a5fcd210ff31ebfad9f56e991dee9a21a43aa5129784cb61a0f087990205';

// The sealed sample is a real session envelope so the Swift pin can both open it
// and decode the plaintext. Sealed with the mac->phone key at counter 5.
const SAMPLE_PLAINTEXT =
  '{"v":1,"id":"00000000-0000-4000-8000-000000000000","type":"session.pong","payload":{"ts":1720000000000}}';
const SAMPLE_COUNTER = 5;

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export interface SessionCryptoVector {
  description: string;
  label: string;
  keys: {
    macIdentityPriv: string;
    phoneIdentityPriv: string;
    macEphPriv: string;
    phoneEphPriv: string;
  };
  derivedPublicKeys: {
    macIdentityPub: string;
    phoneIdentityPub: string;
    macEphPub: string;
    phoneEphPub: string;
  };
  expected: {
    sendKeyMacToPhone: string;
    sendKeyPhoneToMac: string;
    handshakeSigMac: string;
    handshakeSigPhone: string;
    sealedSample: {
      direction: string;
      plaintext: string;
      counter: number;
      ciphertext: string;
    };
  };
}

/** Compute the full interop vector object from the fixed keys. */
export function buildSessionCryptoVector(sodium: SodiumLike): SessionCryptoVector {
  const macIdentitySeed = fromHex(MAC_IDENTITY_PRIV_HEX);
  const phoneIdentitySeed = fromHex(PHONE_IDENTITY_PRIV_HEX);
  const macEphPriv = fromHex(MAC_EPH_PRIV_HEX);
  const phoneEphPriv = fromHex(PHONE_EPH_PRIV_HEX);

  const macIdentityPub = sodium.signSeedKeypair(macIdentitySeed).publicKey;
  const phoneIdentityPub = sodium.signSeedKeypair(phoneIdentitySeed).publicKey;
  const macEphPub = sodium.scalarMultBase(macEphPriv);
  const phoneEphPub = sodium.scalarMultBase(phoneEphPriv);

  // Role-independent transcript (identical bytes from either side).
  const transcript = handshakeTranscript({
    role: 'mac',
    localIdentityPublicKey: macIdentityPub,
    localEphemeralPublicKey: macEphPub,
    peerIdentityPublicKey: phoneIdentityPub,
    peerEphemeralPublicKey: phoneEphPub,
  });

  const sharedSecret = sodium.scalarMult(macEphPriv, phoneEphPub);
  const sendKeyMacToPhone = hkdfSha256(sharedSecret, transcript, utf8Bytes(MAC_TO_PHONE_INFO), 32);
  const sendKeyPhoneToMac = hkdfSha256(sharedSecret, transcript, utf8Bytes(PHONE_TO_MAC_INFO), 32);

  const handshakeSigMac = localHandshakeSignature(sodium, {
    role: 'mac',
    localIdentitySeed: macIdentitySeed,
    localEphemeralPublicKey: macEphPub,
    peerIdentityPublicKey: phoneIdentityPub,
    peerEphemeralPublicKey: phoneEphPub,
  });
  const handshakeSigPhone = localHandshakeSignature(sodium, {
    role: 'phone',
    localIdentitySeed: phoneIdentitySeed,
    localEphemeralPublicKey: phoneEphPub,
    peerIdentityPublicKey: macIdentityPub,
    peerEphemeralPublicKey: macEphPub,
  });

  const sealed = sealFrameAt(
    sodium,
    sendKeyMacToPhone,
    MAC_TO_PHONE_SALT,
    BigInt(SAMPLE_COUNTER),
    utf8Bytes(SAMPLE_PLAINTEXT),
  );

  return {
    description:
      'Zentty companion session-crypto interop vector. TEST-ONLY private keys — ' +
      'never reuse. Derivation mirrors CompanionSessionCrypto.swift; the Swift pin ' +
      'asserts CryptoKit reproduces every expected value byte-for-byte.',
    label: HANDSHAKE_LABEL,
    keys: {
      macIdentityPriv: encodeBase64Url(macIdentitySeed),
      phoneIdentityPriv: encodeBase64Url(phoneIdentitySeed),
      macEphPriv: encodeBase64Url(macEphPriv),
      phoneEphPriv: encodeBase64Url(phoneEphPriv),
    },
    derivedPublicKeys: {
      macIdentityPub: encodeBase64Url(macIdentityPub),
      phoneIdentityPub: encodeBase64Url(phoneIdentityPub),
      macEphPub: encodeBase64Url(macEphPub),
      phoneEphPub: encodeBase64Url(phoneEphPub),
    },
    expected: {
      sendKeyMacToPhone: encodeBase64Url(sendKeyMacToPhone),
      sendKeyPhoneToMac: encodeBase64Url(sendKeyPhoneToMac),
      handshakeSigMac: encodeBase64Url(handshakeSigMac),
      handshakeSigPhone: encodeBase64Url(handshakeSigPhone),
      sealedSample: {
        direction: 'mac->phone',
        plaintext: SAMPLE_PLAINTEXT,
        counter: SAMPLE_COUNTER,
        ciphertext: encodeBase64Url(sealed),
      },
    },
  };
}

/** Canonical on-disk serialization (2-space JSON + trailing newline). */
export function serializeVector(vector: SessionCryptoVector): string {
  return `${JSON.stringify(vector, null, 2)}\n`;
}
