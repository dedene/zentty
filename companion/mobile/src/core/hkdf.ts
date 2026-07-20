/**
 * SHA-256, HMAC-SHA256, and HKDF-SHA256 in dependency-free TypeScript.
 *
 * Why hand-rolled instead of a libsodium call: the base `libsodium-wrappers`
 * build exposes neither `crypto_hash_sha256`, `crypto_auth_hmacsha256`, nor
 * `crypto_kdf_hkdf_sha256_*`, and react-native-libsodium 1.7.0 exposes only the
 * `_unstable_crypto_kdf_hkdf_sha256_*` names with a non-obvious argument order.
 * These three functions are keyless, deterministic, and standardized, so
 * computing them here guarantees byte-identical output to the Mac's CryptoKit
 * `HKDF<SHA256>` on every platform, and keeps the native `SodiumLike` surface
 * down to the operations that genuinely need native crypto.
 *
 * Verified against the RFC 6234 SHA-256, RFC 4231 HMAC-SHA256, and RFC 5869
 * HKDF-SHA256 test vectors (see hkdf.test.ts).
 */

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const BLOCK_BYTES = 64;
export const SHA256_BYTES = 32;

/** SHA-256 digest of `message`. */
export function sha256(message: Uint8Array): Uint8Array {
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  const bitLen = message.length * 8;
  // Padded length: message + 0x80 + zeros + 8-byte length, rounded to 64.
  const withOne = message.length + 1;
  const total = withOne + ((BLOCK_BYTES - ((withOne + 8) % BLOCK_BYTES)) % BLOCK_BYTES) + 8;
  const buf = new Uint8Array(total);
  buf.set(message);
  buf[message.length] = 0x80;
  // 64-bit big-endian bit length in the final 8 bytes (high word fits <= 2^32).
  const hi = Math.floor(bitLen / 0x100000000);
  const lo = bitLen >>> 0;
  buf[total - 8] = (hi >>> 24) & 0xff;
  buf[total - 7] = (hi >>> 16) & 0xff;
  buf[total - 6] = (hi >>> 8) & 0xff;
  buf[total - 5] = hi & 0xff;
  buf[total - 4] = (lo >>> 24) & 0xff;
  buf[total - 3] = (lo >>> 16) & 0xff;
  buf[total - 2] = (lo >>> 8) & 0xff;
  buf[total - 1] = lo & 0xff;

  const w = new Uint32Array(64);
  for (let off = 0; off < total; off += BLOCK_BYTES) {
    for (let i = 0; i < 16; i += 1) {
      const j = off + i * 4;
      w[i] = ((buf[j] << 24) | (buf[j + 1] << 16) | (buf[j + 2] << 8) | buf[j + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i += 1) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h[0];
    let b = h[1];
    let c = h[2];
    let d = h[3];
    let e = h[4];
    let f = h[5];
    let g = h[6];
    let hh = h[7];

    for (let i = 0; i < 64; i += 1) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }

    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }

  const out = new Uint8Array(SHA256_BYTES);
  for (let i = 0; i < 8; i += 1) {
    out[i * 4] = (h[i] >>> 24) & 0xff;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xff;
    out[i * 4 + 3] = h[i] & 0xff;
  }
  return out;
}

function rotr(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0;
}

/** HMAC-SHA256 (RFC 2104) with an arbitrary-length key. */
export function hmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
  let k = key;
  if (k.length > BLOCK_BYTES) {
    k = sha256(k);
  }
  const kPad = new Uint8Array(BLOCK_BYTES);
  kPad.set(k);

  const inner = new Uint8Array(BLOCK_BYTES + message.length);
  const outer = new Uint8Array(BLOCK_BYTES + SHA256_BYTES);
  for (let i = 0; i < BLOCK_BYTES; i += 1) {
    inner[i] = kPad[i] ^ 0x36;
    outer[i] = kPad[i] ^ 0x5c;
  }
  inner.set(message, BLOCK_BYTES);
  const innerHash = sha256(inner);
  outer.set(innerHash, BLOCK_BYTES);
  return sha256(outer);
}

/** HKDF-Extract (RFC 5869 §2.2): PRK = HMAC(salt, IKM). */
export function hkdfExtract(salt: Uint8Array, ikm: Uint8Array): Uint8Array {
  return hmacSha256(salt, ikm);
}

/** HKDF-Expand (RFC 5869 §2.3). */
export function hkdfExpand(prk: Uint8Array, info: Uint8Array, length: number): Uint8Array {
  const n = Math.ceil(length / SHA256_BYTES);
  if (n > 255) {
    throw new Error('hkdf: requested length too large');
  }
  const okm = new Uint8Array(n * SHA256_BYTES);
  let prev: Uint8Array = new Uint8Array(0);
  for (let i = 0; i < n; i += 1) {
    const input = new Uint8Array(prev.length + info.length + 1);
    input.set(prev, 0);
    input.set(info, prev.length);
    input[input.length - 1] = i + 1;
    prev = hmacSha256(prk, input);
    okm.set(prev, i * SHA256_BYTES);
  }
  return okm.subarray(0, length);
}

/**
 * Full HKDF-SHA256 (extract + expand). Bit-identical to CryptoKit's
 * `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`, which is
 * what the Mac's `CompanionHandshake` uses to derive the two directional keys.
 */
export function hkdfSha256(
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  length: number,
): Uint8Array {
  return hkdfExpand(hkdfExtract(salt, ikm), info, length);
}
