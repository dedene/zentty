/**
 * Key-material builder for the iOS Notification Service Extension (NSE).
 *
 * The NSE unseals wake banners offline, outside the app process, so it cannot
 * run the JS crypto stack. Instead the app mirrors the *already-converted*
 * X25519 material into the shared App Group, and the NSE redoes only the last
 * two steps natively: X25519 ECDH + HKDF-SHA256 + ChaCha20-Poly1305 open
 * (CryptoKit). This module produces exactly the JSON shape the NSE parses in
 * `plugins/notification-service/NotificationService.swift` (`KeyMaterial.load`):
 *
 *   {
 *     "phoneX25519Priv": "<base64url raw 32-byte X25519 private scalar>",
 *     "macX25519Pub":    { "<macDeviceId>": "<base64url raw 32-byte X25519 public key>" }
 *   }
 *
 * `macDeviceId` is the base64url Ed25519 identity public key — the same string
 * the Mac puts in the wake envelope (`zentty.macDeviceId`), so the NSE can look
 * up the right public key without any further mapping.
 *
 * The material is equivalent to what {@link derivePushKey} consumes: feeding it
 * through X25519(phonePriv, macPub) + HKDF(salt = "zentty-push/v1",
 * info = "zentty-push") yields the identical seal key (locked to the checked-in
 * push-seal vector by pushKeyMaterial.test.ts).
 */

import { decodeBase64Url, encodeBase64Url } from './base64url';
import type { SodiumLike } from './sodium';
import type { PairedMac } from './storage';

/** The JSON blob the NSE reads from the App Group `UserDefaults` suite. */
export interface PushKeyMaterial {
  /** base64url raw 32-byte X25519 private scalar of this phone's identity. */
  phoneX25519Priv: string;
  /** macDeviceId → base64url raw 32-byte X25519 public key of that Mac's identity. */
  macX25519Pub: Record<string, string>;
}

/**
 * Build the NSE key-material blob from the phone identity seed and the current
 * pairings. Deterministic and offline — safe to rebuild and re-mirror wholesale
 * after every pair/unpair (full-replace semantics).
 */
export function buildPushKeyMaterial(
  sodium: SodiumLike,
  params: {
    /** The phone's Ed25519 identity seed. */
    phoneIdentitySeed: Uint8Array;
    macs: PairedMac[];
  },
): PushKeyMaterial {
  const phoneKeypair = sodium.signSeedKeypair(params.phoneIdentitySeed);
  const phoneX25519Priv = sodium.ed25519SecretKeyToX25519(phoneKeypair.secretKey);
  const macX25519Pub: Record<string, string> = {};
  for (const mac of params.macs) {
    macX25519Pub[mac.macDeviceId] = encodeBase64Url(
      sodium.ed25519PublicKeyToX25519(decodeBase64Url(mac.macPubKey)),
    );
  }
  return {
    phoneX25519Priv: encodeBase64Url(phoneX25519Priv),
    macX25519Pub,
  };
}
