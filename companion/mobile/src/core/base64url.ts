/**
 * URL-safe, unpadded Base64 (RFC 4648 §5) — the phone-side twin of the Mac's
 * `CompanionBase64URL` (Zentty/Companion/Security/CompanionDeviceIdentity.swift).
 *
 * The wire spells every public key, signature, nonce, device id, and sealed blob
 * this way, so the two ends must agree byte-for-byte. Implemented without Node
 * `Buffer` or `btoa`/`atob` so it runs identically under Hermes/React Native and
 * a Node test runner.
 */

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

const DECODE_TABLE: Int16Array = (() => {
  const table = new Int16Array(128).fill(-1);
  for (let i = 0; i < ALPHABET.length; i += 1) {
    table[ALPHABET.charCodeAt(i)] = i;
  }
  // Accept standard base64 spellings too, so a padded/`+`/`/` string still
  // decodes (the Mac's decoder is equally lenient on input).
  table['+'.charCodeAt(0)] = 62;
  table['/'.charCodeAt(0)] = 63;
  return table;
})();

/** Encode raw bytes as unpadded base64url. */
export function encodeBase64Url(bytes: Uint8Array): string {
  let out = '';
  let i = 0;
  for (; i + 3 <= bytes.length; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out +=
      ALPHABET[(n >> 18) & 63] +
      ALPHABET[(n >> 12) & 63] +
      ALPHABET[(n >> 6) & 63] +
      ALPHABET[n & 63];
  }
  const rem = bytes.length - i;
  if (rem === 1) {
    const n = bytes[i] << 16;
    out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63];
  } else if (rem === 2) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += ALPHABET[(n >> 18) & 63] + ALPHABET[(n >> 12) & 63] + ALPHABET[(n >> 6) & 63];
  }
  return out;
}

/**
 * Decode a base64url (or plain base64, padded or not) string to bytes. Throws on
 * a character outside the alphabet — callers that must not throw wrap this.
 */
export function decodeBase64Url(input: string): Uint8Array {
  // Strip padding; we recover length from the character count.
  let s = input;
  while (s.endsWith('=')) {
    s = s.slice(0, -1);
  }
  const len = s.length;
  const fullGroups = Math.floor(len / 4);
  const rem = len - fullGroups * 4;
  if (rem === 1) {
    throw new Error('invalid base64url length');
  }
  const outLen = fullGroups * 3 + (rem === 2 ? 1 : rem === 3 ? 2 : 0);
  const out = new Uint8Array(outLen);

  const sextet = (ch: number): number => {
    const v = ch < 128 ? DECODE_TABLE[ch] : -1;
    if (v < 0) {
      throw new Error('invalid base64url character');
    }
    return v;
  };

  let o = 0;
  let p = 0;
  for (let g = 0; g < fullGroups; g += 1) {
    const a = sextet(s.charCodeAt(p));
    const b = sextet(s.charCodeAt(p + 1));
    const c = sextet(s.charCodeAt(p + 2));
    const d = sextet(s.charCodeAt(p + 3));
    p += 4;
    out[o++] = (a << 2) | (b >> 4);
    out[o++] = ((b & 15) << 4) | (c >> 2);
    out[o++] = ((c & 3) << 6) | d;
  }
  if (rem === 2) {
    const a = sextet(s.charCodeAt(p));
    const b = sextet(s.charCodeAt(p + 1));
    out[o++] = (a << 2) | (b >> 4);
  } else if (rem === 3) {
    const a = sextet(s.charCodeAt(p));
    const b = sextet(s.charCodeAt(p + 1));
    const c = sextet(s.charCodeAt(p + 2));
    out[o++] = (a << 2) | (b >> 4);
    out[o++] = ((b & 15) << 4) | (c >> 2);
  }
  return out;
}

const UNPADDED = /^[A-Za-z0-9_-]+$/;

/**
 * Non-empty and spelled with only unpadded base64url characters. Mirrors
 * `CompanionBase64URL.isValidUnpadded` and the `Base64Url` zod schema — the relay
 * transport rejects padded/empty strings outright.
 */
export function isValidUnpaddedBase64Url(s: string): boolean {
  return s.length > 0 && UNPADDED.test(s);
}
