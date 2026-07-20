/**
 * Phone side of the Zentty companion session crypto. A byte-for-byte mirror of
 * the Mac's `CompanionHandshake` + `CompanionSessionCrypto`
 * (Zentty/Companion/Security/CompanionSessionCrypto.swift).
 *
 * Wire contract (both ends must agree exactly):
 * - Shared secret: X25519 ECDH over the per-session ephemeral keys.
 * - Directional keys: HKDF-SHA256(ikm = sharedSecret, salt = transcript,
 *   info = <direction>), 32 bytes each.
 * - Transcript (also the HKDF salt): the UTF-8 label followed by the raw 32-byte
 *   public keys in fixed order — mac identity, phone identity, mac ephemeral,
 *   phone ephemeral. Role-independent: both ends produce identical bytes.
 * - Each side signs the transcript with its Ed25519 identity key; the peer
 *   verifies with the identity it pinned at pairing.
 * - AEAD: ChaCha20-Poly1305-IETF. Sealed frame = counter (8B big-endian) ||
 *   ciphertext || tag (16B). The 12-byte nonce is the 4-byte directional salt
 *   followed by the same big-endian counter, and is never transmitted whole.
 * - Monotonic per-direction counters give replay protection: an opened frame's
 *   counter must strictly exceed the last successfully opened one.
 */

import { hkdfSha256 } from './hkdf';
import type { SodiumLike } from './sodium';

// MARK: - Constants (mirror CompanionHandshake)

export const HANDSHAKE_LABEL = 'zentty-companion/v1/handshake';
export const MAC_TO_PHONE_INFO = 'zentty-companion/v1/mac->phone';
export const PHONE_TO_MAC_INFO = 'zentty-companion/v1/phone->mac';

/** 4-byte nonce domain separators ("m>p\0" / "p>m\0"). */
export const MAC_TO_PHONE_SALT = new Uint8Array([0x6d, 0x3e, 0x70, 0x00]);
export const PHONE_TO_MAC_SALT = new Uint8Array([0x70, 0x3e, 0x6d, 0x00]);

const KEY_BYTES = 32;
const TAG_BYTES = 16;
const COUNTER_BYTES = 8;
const MAX_COUNTER = (1n << 64n) - 1n;

export type EndpointRole = 'mac' | 'phone';

// MARK: - Errors

export type CompanionCryptoErrorCode =
  | 'invalidHandshakeSignature'
  | 'replayDetected'
  | 'malformedSealedFrame'
  | 'sendCounterExhausted';

/** Mirrors Swift's `CompanionCryptoError`. */
export class CompanionCryptoError extends Error {
  readonly code: CompanionCryptoErrorCode;
  constructor(code: CompanionCryptoErrorCode) {
    super(code);
    this.name = 'CompanionCryptoError';
    this.code = code;
  }
}

// MARK: - Byte helpers

const utf8 = new TextEncoder();

export function utf8Bytes(s: string): Uint8Array {
  return utf8.encode(s);
}

function concat(...parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) {
    total += p.length;
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function bigEndianU64(value: bigint): Uint8Array {
  const out = new Uint8Array(COUNTER_BYTES);
  let v = value;
  for (let i = COUNTER_BYTES - 1; i >= 0; i -= 1) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

function readBigEndianU64(bytes: Uint8Array): bigint {
  let v = 0n;
  for (let i = 0; i < COUNTER_BYTES; i += 1) {
    v = (v << 8n) | BigInt(bytes[i]);
  }
  return v;
}

// MARK: - Handshake

/**
 * Build the canonical, role-independent transcript: the label followed by mac
 * identity, phone identity, mac ephemeral, phone ephemeral (each a raw 32-byte
 * key). Both endpoints produce identical bytes.
 */
export function handshakeTranscript(params: {
  role: EndpointRole;
  localIdentityPublicKey: Uint8Array;
  localEphemeralPublicKey: Uint8Array;
  peerIdentityPublicKey: Uint8Array;
  peerEphemeralPublicKey: Uint8Array;
}): Uint8Array {
  const { role } = params;
  const macIdentity =
    role === 'mac' ? params.localIdentityPublicKey : params.peerIdentityPublicKey;
  const phoneIdentity =
    role === 'mac' ? params.peerIdentityPublicKey : params.localIdentityPublicKey;
  const macEphemeral =
    role === 'mac' ? params.localEphemeralPublicKey : params.peerEphemeralPublicKey;
  const phoneEphemeral =
    role === 'mac' ? params.peerEphemeralPublicKey : params.localEphemeralPublicKey;
  return concat(
    utf8Bytes(HANDSHAKE_LABEL),
    macIdentity,
    phoneIdentity,
    macEphemeral,
    phoneEphemeral,
  );
}

/**
 * This endpoint's Ed25519 signature over the handshake transcript. The peer feeds
 * the result to {@link establishSession} as `peerSignature`.
 */
export function localHandshakeSignature(
  sodium: SodiumLike,
  params: {
    role: EndpointRole;
    localIdentitySeed: Uint8Array;
    localEphemeralPublicKey: Uint8Array;
    peerIdentityPublicKey: Uint8Array;
    peerEphemeralPublicKey: Uint8Array;
  },
): Uint8Array {
  const keypair = sodium.signSeedKeypair(params.localIdentitySeed);
  const transcript = handshakeTranscript({
    role: params.role,
    localIdentityPublicKey: keypair.publicKey,
    localEphemeralPublicKey: params.localEphemeralPublicKey,
    peerIdentityPublicKey: params.peerIdentityPublicKey,
    peerEphemeralPublicKey: params.peerEphemeralPublicKey,
  });
  return sodium.signDetached(transcript, keypair.secretKey);
}

/**
 * Verify the peer's transcript signature, run ECDH, derive the two directional
 * keys, and return a session bound to `role`. Throws
 * `CompanionCryptoError('invalidHandshakeSignature')` if the peer signature does
 * not verify against its pinned identity.
 */
export function establishSession(
  sodium: SodiumLike,
  params: {
    role: EndpointRole;
    localIdentitySeed: Uint8Array;
    localEphemeralPrivateKey: Uint8Array;
    localEphemeralPublicKey: Uint8Array;
    peerIdentityPublicKey: Uint8Array;
    peerEphemeralPublicKey: Uint8Array;
    peerSignature: Uint8Array;
  },
): CompanionSessionCrypto {
  const keypair = sodium.signSeedKeypair(params.localIdentitySeed);
  const transcript = handshakeTranscript({
    role: params.role,
    localIdentityPublicKey: keypair.publicKey,
    localEphemeralPublicKey: params.localEphemeralPublicKey,
    peerIdentityPublicKey: params.peerIdentityPublicKey,
    peerEphemeralPublicKey: params.peerEphemeralPublicKey,
  });

  const ok = sodium.signVerifyDetached(
    params.peerSignature,
    transcript,
    params.peerIdentityPublicKey,
  );
  if (!ok) {
    throw new CompanionCryptoError('invalidHandshakeSignature');
  }

  const sharedSecret = sodium.scalarMult(
    params.localEphemeralPrivateKey,
    params.peerEphemeralPublicKey,
  );
  const macToPhoneKey = hkdfSha256(sharedSecret, transcript, utf8Bytes(MAC_TO_PHONE_INFO), KEY_BYTES);
  const phoneToMacKey = hkdfSha256(sharedSecret, transcript, utf8Bytes(PHONE_TO_MAC_INFO), KEY_BYTES);

  if (params.role === 'mac') {
    return new CompanionSessionCrypto(sodium, {
      sendKey: macToPhoneKey,
      sendSalt: MAC_TO_PHONE_SALT,
      receiveKey: phoneToMacKey,
      receiveSalt: PHONE_TO_MAC_SALT,
    });
  }
  return new CompanionSessionCrypto(sodium, {
    sendKey: phoneToMacKey,
    sendSalt: PHONE_TO_MAC_SALT,
    receiveKey: macToPhoneKey,
    receiveSalt: MAC_TO_PHONE_SALT,
  });
}

// MARK: - Session crypto

interface SessionKeys {
  sendKey: Uint8Array;
  sendSalt: Uint8Array;
  receiveKey: Uint8Array;
  receiveSalt: Uint8Array;
}

/**
 * A directional AEAD channel. Seals outbound frames with a monotonic send
 * counter and opens inbound frames, rejecting any whose counter does not advance.
 */
export class CompanionSessionCrypto {
  private readonly sodium: SodiumLike;
  private readonly keys: SessionKeys;
  private sendCounter = 0n;
  private lastReceivedCounter: bigint | null = null;

  constructor(sodium: SodiumLike, keys: SessionKeys) {
    this.sodium = sodium;
    this.keys = keys;
  }

  /** Seals `plaintext` and advances the send counter. */
  seal(plaintext: Uint8Array): Uint8Array {
    if (this.sendCounter === MAX_COUNTER) {
      throw new CompanionCryptoError('sendCounterExhausted');
    }
    const counter = this.sendCounter;
    const nonce = concat(this.keys.sendSalt, bigEndianU64(counter));
    const box = this.sodium.aeadEncrypt(plaintext, nonce, this.keys.sendKey);
    this.sendCounter += 1n;
    return concat(bigEndianU64(counter), box);
  }

  /**
   * Opens a sealed frame. Throws `replayDetected` if the counter does not
   * strictly exceed the last successfully opened one; the high-water mark
   * advances only on successful authentication.
   */
  open(sealed: Uint8Array): Uint8Array {
    if (sealed.length < COUNTER_BYTES + TAG_BYTES) {
      throw new CompanionCryptoError('malformedSealedFrame');
    }
    const counter = readBigEndianU64(sealed.subarray(0, COUNTER_BYTES));
    if (this.lastReceivedCounter !== null && counter <= this.lastReceivedCounter) {
      throw new CompanionCryptoError('replayDetected');
    }
    const body = sealed.subarray(COUNTER_BYTES);
    const nonce = concat(this.keys.receiveSalt, bigEndianU64(counter));
    const plaintext = this.sodium.aeadDecrypt(body, nonce, this.keys.receiveKey);
    this.lastReceivedCounter = counter;
    return plaintext;
  }

  /** The next counter this channel will seal with (test/introspection aid). */
  get nextSendCounter(): bigint {
    return this.sendCounter;
  }
}

/**
 * Seal a single frame at an explicit counter with an explicit direction, without
 * mutating any session state. Used by the interop-vector generator to produce a
 * deterministic sample the Swift pin can open.
 */
export function sealFrameAt(
  sodium: SodiumLike,
  key: Uint8Array,
  salt: Uint8Array,
  counter: bigint,
  plaintext: Uint8Array,
): Uint8Array {
  const nonce = concat(salt, bigEndianU64(counter));
  const box = sodium.aeadEncrypt(plaintext, nonce, key);
  return concat(bigEndianU64(counter), box);
}
