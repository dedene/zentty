/**
 * Runtime native-crypto adapter: implements the core's {@link SodiumLike} with
 * pure-TypeScript @stablelib primitives plus expo-crypto for the CSPRNG.
 *
 * Why not react-native-libsodium: its 1.7.0 native binding ships neither X25519
 * (`crypto_scalarmult` / `_base`) nor ChaCha20-Poly1305-IETF, so the encrypted
 * session cannot run on a real device. @stablelib gives a self-contained,
 * audited, dependency-light implementation of exactly the three primitives the
 * session needs, and its X25519 clamps the scalar identically to libsodium /
 * CryptoKit, so the checked-in interop vectors stay byte-identical.
 *
 * The Node vector suite keeps using the libsodium-wrappers adapter
 * (scripts/loadSodium.ts) so two independent implementations cross-check every
 * derived key, signature, and sealed frame against the Mac's CryptoKit pin.
 *
 * Randomness is injected (default: expo-crypto) so the pure-crypto factory can be
 * driven headlessly in the dual-adapter vector test without pulling a native
 * module.
 */
import { ChaCha20Poly1305 } from '@stablelib/chacha20poly1305';
import * as ed25519 from '@stablelib/ed25519';
import * as x25519 from '@stablelib/x25519';
import { getRandomBytes } from 'expo-crypto';

import { type SodiumLike } from '@/core';

/** Random-bytes source injected into {@link createStablelibSodium}. */
export type RandomBytes = (length: number) => Uint8Array;

/**
 * Build a {@link SodiumLike} backed by @stablelib. `randomBytes` supplies the
 * CSPRNG; on device this is expo-crypto's `getRandomBytes` (see {@link getSodium}).
 */
export function createStablelibSodium(randomBytes: RandomBytes): SodiumLike {
  return {
    scalarMult: (privateKey, publicKey) => x25519.scalarMult(privateKey, publicKey),
    scalarMultBase: (privateKey) => x25519.scalarMultBase(privateKey),
    signSeedKeypair: (seed) => {
      const pair = ed25519.generateKeyPairFromSeed(seed);
      return { publicKey: pair.publicKey, secretKey: pair.secretKey };
    },
    signDetached: (message, secretKey) => ed25519.sign(secretKey, message),
    signVerifyDetached: (signature, message, publicKey) =>
      ed25519.verify(publicKey, message, signature),
    aeadEncrypt: (plaintext, nonce, key) => new ChaCha20Poly1305(key).seal(nonce, plaintext),
    aeadDecrypt: (ciphertextWithTag, nonce, key) => {
      const opened = new ChaCha20Poly1305(key).open(nonce, ciphertextWithTag);
      if (opened === null) {
        throw new Error('chacha20poly1305: authentication failed');
      }
      return opened;
    },
    ed25519PublicKeyToX25519: (publicKey) => ed25519.convertPublicKeyToX25519(publicKey),
    ed25519SecretKeyToX25519: (secretKey) => ed25519.convertSecretKeyToX25519(secretKey),
    randomBytes: (length) => randomBytes(length),
  };
}

let cached: SodiumLike | undefined;

/**
 * Return the memoized runtime adapter. Async to keep the call sites identical to
 * the previous WASM-init adapter, but @stablelib needs no async setup.
 */
export function getSodium(): Promise<SodiumLike> {
  if (!cached) {
    cached = createStablelibSodium(getRandomBytes);
  }
  return Promise.resolve(cached);
}
