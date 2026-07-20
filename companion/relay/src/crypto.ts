import { createPublicKey, verify as edVerify } from 'node:crypto';

// Relay-auth signature verification and the pairing-frame classifier.
//
// Ed25519 interop with the Swift/CryptoKit and react-native-libsodium sides:
// devices send the raw 32-byte public key as unpadded base64url (also their
// deviceId). Node has no direct "raw Ed25519 pubkey -> KeyObject" API, so we go
// through a JWK (`kty: OKP, crv: Ed25519, x: <base64url raw>`) — the simplest
// correct path on Node 24. The signature covers the UTF-8 bytes of
// `RELAY_AUTH_PREFIX + nonce`, where `nonce` is the base64url string exactly as
// sent in relay.challenge.

/** Domain-separated prefix signed alongside the challenge nonce. */
export const RELAY_AUTH_PREFIX = 'zentty-relay-auth:';

/** Raw Ed25519 public keys are always 32 bytes. */
const ED25519_RAW_LEN = 32;

export interface RelayAuthInput {
  deviceId: string;
  pubKey: string;
  sig: string;
}

/**
 * Verify a relay.auth frame against the challenge nonce. Returns true only when
 * the public key is a valid 32-byte Ed25519 key, `deviceId` is its canonical
 * base64url encoding, and the signature validates. Never throws.
 */
export function verifyRelayAuth(auth: RelayAuthInput, nonce: string): boolean {
  try {
    const rawPub = Buffer.from(auth.pubKey, 'base64url');
    if (rawPub.length !== ED25519_RAW_LEN) {
      return false;
    }
    // deviceId must be the canonical base64url of the raw key (no spoofing an
    // id that does not match the presented key).
    if (auth.deviceId !== rawPub.toString('base64url')) {
      return false;
    }
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: rawPub.toString('base64url') },
      format: 'jwk',
    });
    const message = Buffer.from(RELAY_AUTH_PREFIX + nonce, 'utf8');
    const signature = Buffer.from(auth.sig, 'base64url');
    return edVerify(null, message, key, signature);
  } catch {
    return false;
  }
}

export interface SealedClassification {
  /** The sealed blob decoded to a plaintext `pairing.*` envelope. */
  isPairing: boolean;
  /** A pairing envelope whose decoded size exceeds the pairing cap. */
  pairingTooLarge: boolean;
}

/**
 * Classify a relay.frame's `sealed` payload. The relay CAN read plaintext
 * pairing bootstrap frames (they are not E2E-encrypted, by design), so a frame
 * whose sealed blob base64url-decodes to JSON with a `pairing.*` type is metered
 * against the tighter pairing window. Anything that fails to decode or parse —
 * i.e. an encrypted session frame — is treated as non-pairing. Never throws.
 */
export function classifySealed(
  sealed: string,
  maxPairingSealedBytes: number,
): SealedClassification {
  try {
    const bytes = Buffer.from(sealed, 'base64url');
    const parsed: unknown = JSON.parse(bytes.toString('utf8'));
    if (
      parsed !== null &&
      typeof parsed === 'object' &&
      typeof (parsed as { type?: unknown }).type === 'string' &&
      (parsed as { type: string }).type.startsWith('pairing.')
    ) {
      return {
        isPairing: true,
        pairingTooLarge: bytes.length > maxPairingSealedBytes,
      };
    }
  } catch {
    // Not decodable/parseable as plaintext JSON -> an encrypted frame.
  }
  return { isPairing: false, pairingTooLarge: false };
}
