/**
 * Offline unseal for end-to-end push wake payloads — the phone mirror of the
 * Mac's push-seal scheme.
 *
 * A wake notification carries its real content sealed to this phone. Because the
 * phone is asleep when it arrives, the key must be derivable *offline* from data
 * the phone already holds: the paired Mac's identity public key (pinned at
 * pairing) and this phone's own identity private key. No session, no network.
 *
 * Scheme (must match the Mac's push-seal implementation byte-for-byte):
 *
 *  1. Both identities are Ed25519. Convert each to its X25519 (Montgomery) form:
 *     the Mac public key with `ed25519PublicKeyToX25519`, the phone secret key
 *     with `ed25519SecretKeyToX25519`. This is the standard birationally-mapped
 *     conversion libsodium (`crypto_sign_ed25519_*_to_curve25519`) and CryptoKit
 *     both implement, so the two ends land on the same Curve25519 points.
 *  2. Shared secret = X25519(phoneX25519Priv, macX25519Pub). ECDH is symmetric, so
 *     the Mac computes the identical value as X25519(macX25519Priv, phoneX25519Pub).
 *  3. Key = HKDF-SHA256(ikm = sharedSecret, salt = utf8("zentty-push/v1"),
 *     info = utf8("{@link PUSH_SEAL_LABEL}"), length = 32). The salt is fixed,
 *     non-empty, and versioned to match the Mac (`CompanionPushSeal.hkdfSalt`)
 *     byte-for-byte — there is no empty-salt ambiguity to resolve.
 *  4. Sealed blob = nonce (12 bytes) || ChaCha20-Poly1305-IETF(plaintext) with tag
 *     appended. The nonce is random per seal and prepended, so no counter/session
 *     state is needed — each wake is an independent one-shot box.
 *
 * The checked-in push-seal vector (companion/wire/vectors/crypto/push-seal.json)
 * is the interop pin: the phone unseal here and the Mac seal must agree on it.
 */

import { hkdfSha256 } from './hkdf';
import type { SodiumLike } from './sodium';

const utf8 = new TextEncoder();

/** HKDF `info` domain-separating the push key from the session keys. */
export const PUSH_SEAL_LABEL = 'zentty-push';

/**
 * HKDF `salt` — fixed, non-empty, and versioned. Must equal the Mac's
 * `CompanionPushSeal.hkdfSalt` (`Data("zentty-push/v1".utf8)`) byte-for-byte.
 */
export const PUSH_SEAL_SALT = 'zentty-push/v1';

const KEY_BYTES = 32;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const SALT = utf8.encode(PUSH_SEAL_SALT);

/**
 * Derive the 32-byte push-seal key from the Mac's Ed25519 identity public key and
 * this phone's Ed25519 identity seed. Deterministic and offline.
 */
export function derivePushKey(
  sodium: SodiumLike,
  params: {
    /** Mac's 32-byte Ed25519 identity public key. */
    macIdentityPublicKey: Uint8Array;
    /** Phone's 32-byte Ed25519 identity seed. */
    phoneIdentitySeed: Uint8Array;
  },
): Uint8Array {
  const macX25519Pub = sodium.ed25519PublicKeyToX25519(params.macIdentityPublicKey);
  const phoneKeypair = sodium.signSeedKeypair(params.phoneIdentitySeed);
  const phoneX25519Priv = sodium.ed25519SecretKeyToX25519(phoneKeypair.secretKey);
  const shared = sodium.scalarMult(phoneX25519Priv, macX25519Pub);
  return hkdfSha256(shared, SALT, utf8.encode(PUSH_SEAL_LABEL), KEY_BYTES);
}

/**
 * Open a sealed wake blob (`nonce || ciphertext || tag`) with `key`. Throws on a
 * malformed blob or authentication failure — callers treat either as "ignore this
 * notification".
 */
export function unsealPush(sodium: SodiumLike, key: Uint8Array, sealed: Uint8Array): Uint8Array {
  if (sealed.length < NONCE_BYTES + TAG_BYTES) {
    throw new Error('push unseal: blob too short');
  }
  const nonce = sealed.subarray(0, NONCE_BYTES);
  const box = sealed.subarray(NONCE_BYTES);
  return sodium.aeadDecrypt(box, nonce, key);
}

/**
 * Seal `plaintext` under `key` with an explicit `nonce`, producing
 * `nonce || ciphertext || tag`. The phone never seals wakes in production (the Mac
 * does); this exists for the interop round-trip test and the vector generator, so
 * the phone can prove it opens exactly what the scheme seals.
 */
export function sealPush(
  sodium: SodiumLike,
  key: Uint8Array,
  nonce: Uint8Array,
  plaintext: Uint8Array,
): Uint8Array {
  if (nonce.length !== NONCE_BYTES) {
    throw new Error(`push seal: nonce must be ${NONCE_BYTES} bytes`);
  }
  const box = sodium.aeadEncrypt(plaintext, nonce, key);
  const out = new Uint8Array(nonce.length + box.length);
  out.set(nonce, 0);
  out.set(box, nonce.length);
  return out;
}
