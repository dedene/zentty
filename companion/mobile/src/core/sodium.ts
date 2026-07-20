/**
 * The narrow native-crypto surface the session core depends on, plus an adapter
 * that maps a libsodium-wrappers-shaped module onto it.
 *
 * Only the operations that genuinely need native primitives live here: X25519
 * ECDH, Ed25519 sign/verify, and ChaCha20-Poly1305-IETF AEAD. SHA-256 / HMAC /
 * HKDF are computed in pure TS (see hkdf.ts) so they cannot drift between
 * platforms. Keeping this surface tiny means a react-native-libsodium adapter and
 * a libsodium-wrappers (test) adapter are a few lines each and easy to audit for
 * interop against the Mac's CryptoKit implementation.
 */

/** The subset of native crypto the phone session needs. All inputs/outputs raw bytes. */
export interface SodiumLike {
  /** X25519 scalar multiplication: ECDH(privateKey, publicKey) -> 32-byte shared secret. */
  scalarMult(privateKey: Uint8Array, publicKey: Uint8Array): Uint8Array;
  /** X25519 base-point multiplication: derive the public key for `privateKey`. */
  scalarMultBase(privateKey: Uint8Array): Uint8Array;
  /** Expand a 32-byte Ed25519 seed into a signing keypair (64-byte secret key). */
  signSeedKeypair(seed: Uint8Array): { publicKey: Uint8Array; secretKey: Uint8Array };
  /** Ed25519 detached signature over `message` using a 64-byte secret key. */
  signDetached(message: Uint8Array, secretKey: Uint8Array): Uint8Array;
  /** Verify an Ed25519 detached signature against a 32-byte public key. */
  signVerifyDetached(signature: Uint8Array, message: Uint8Array, publicKey: Uint8Array): boolean;
  /** ChaCha20-Poly1305-IETF seal. Returns ciphertext with the 16-byte tag appended. */
  aeadEncrypt(plaintext: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array;
  /** ChaCha20-Poly1305-IETF open. Throws on authentication failure. */
  aeadDecrypt(ciphertextWithTag: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array;
  /** Cryptographically-random bytes. */
  randomBytes(length: number): Uint8Array;
}

/**
 * The shape of libsodium-wrappers (and react-native-libsodium's web/native
 * surface) that the adapter reaches into. Declared structurally so the core does
 * not take a type dependency on either library.
 */
export interface RawLibsodium {
  crypto_scalarmult(privateKey: Uint8Array, publicKey: Uint8Array): Uint8Array;
  crypto_scalarmult_base(privateKey: Uint8Array): Uint8Array;
  crypto_sign_seed_keypair(seed: Uint8Array): { publicKey: Uint8Array; privateKey: Uint8Array };
  crypto_sign_detached(message: Uint8Array, secretKey: Uint8Array): Uint8Array;
  crypto_sign_verify_detached(
    signature: Uint8Array,
    message: Uint8Array,
    publicKey: Uint8Array,
  ): boolean;
  crypto_aead_chacha20poly1305_ietf_encrypt(
    message: Uint8Array,
    additionalData: Uint8Array | null,
    secretNonce: Uint8Array | null,
    publicNonce: Uint8Array,
    key: Uint8Array,
  ): Uint8Array;
  crypto_aead_chacha20poly1305_ietf_decrypt(
    secretNonce: Uint8Array | null,
    ciphertext: Uint8Array,
    additionalData: Uint8Array | null,
    publicNonce: Uint8Array,
    key: Uint8Array,
  ): Uint8Array;
  randombytes_buf(length: number): Uint8Array;
}

/**
 * Wrap a libsodium-wrappers-shaped module as a {@link SodiumLike}. Works for both
 * `libsodium-wrappers` (test/Node) and react-native-libsodium's compatible
 * surface at runtime; the caller is responsible for awaiting the library's
 * `ready` promise before constructing the adapter.
 */
export function createSodium(raw: RawLibsodium): SodiumLike {
  return {
    scalarMult: (privateKey, publicKey) => raw.crypto_scalarmult(privateKey, publicKey),
    scalarMultBase: (privateKey) => raw.crypto_scalarmult_base(privateKey),
    signSeedKeypair: (seed) => {
      const pair = raw.crypto_sign_seed_keypair(seed);
      return { publicKey: pair.publicKey, secretKey: pair.privateKey };
    },
    signDetached: (message, secretKey) => raw.crypto_sign_detached(message, secretKey),
    signVerifyDetached: (signature, message, publicKey) =>
      raw.crypto_sign_verify_detached(signature, message, publicKey),
    aeadEncrypt: (plaintext, nonce, key) =>
      raw.crypto_aead_chacha20poly1305_ietf_encrypt(plaintext, null, null, nonce, key),
    aeadDecrypt: (ciphertextWithTag, nonce, key) =>
      raw.crypto_aead_chacha20poly1305_ietf_decrypt(null, ciphertextWithTag, null, nonce, key),
    randomBytes: (length) => raw.randombytes_buf(length),
  };
}
