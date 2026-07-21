/**
 * Parsing + routing for a wake notification's data payload.
 *
 * The gateway delivers a deliberately generic visible alert ("An agent needs your
 * attention"); the real, per-pane content rides along end-to-end encrypted in the
 * notification's `data`. This module handles the plaintext envelope around that
 * blob and the shape of the decrypted content, then turns the pair into a route.
 *
 * Envelope (the notification's `data`, set by the Mac and opaque to the gateway):
 *   `{ zentty: { v: 1, macDeviceId, sealed } }`
 *   - `macDeviceId` is the sending Mac's public key (base64url) — not secret; the
 *     phone uses it both to pick the pairing and to derive the unseal key.
 *   - `sealed` is the base64url {@link sealPush} blob.
 *
 * Content (the decrypted JSON): `{ paneId, worklaneId?, title, body }`.
 *
 * NOTE (interop): the Mac side (push-seal scheme) is the authority on the envelope
 * key names and content fields. These shapes mirror the documented scheme; the
 * checked-in push-seal vector is the cross-check that keeps them byte-aligned.
 */

import { decodeBase64Url } from './base64url';
import { derivePushKey, unsealPush } from './pushCrypto';
import type { SodiumLike } from './sodium';

const utf8Decoder = new TextDecoder();

/** The plaintext envelope carried in the notification `data` field. */
export interface PushWakeEnvelope {
  v: number;
  /** Sending Mac's device id (base64url Ed25519 public key). */
  macDeviceId: string;
  /** base64url sealed content blob. */
  sealed: string;
}

/** The decrypted wake content. */
export interface PushWakeContent {
  paneId: string;
  worklaneId?: string;
  title: string;
  body: string;
}

/** A resolved deep-link target for a tapped/received wake. */
export interface PushDeepLink {
  macDeviceId: string;
  paneId: string;
  content: PushWakeContent;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

/**
 * Extract and validate the {@link PushWakeEnvelope} from a notification `data`
 * payload. Returns `undefined` for anything that is not a Zentty wake (so a
 * stray/foreign notification is ignored rather than throwing).
 */
export function parsePushWakeEnvelope(data: unknown): PushWakeEnvelope | undefined {
  if (!isRecord(data)) {
    return undefined;
  }
  const inner = isRecord(data.zentty) ? data.zentty : data;
  const { v, macDeviceId, sealed } = inner as Record<string, unknown>;
  if (typeof macDeviceId !== 'string' || macDeviceId.length === 0) {
    return undefined;
  }
  if (typeof sealed !== 'string' || sealed.length === 0) {
    return undefined;
  }
  return { v: typeof v === 'number' ? v : 1, macDeviceId, sealed };
}

/**
 * Parse decrypted wake bytes into {@link PushWakeContent}. Throws on malformed
 * JSON or a missing `paneId`.
 */
export function parsePushWakeContent(plaintext: Uint8Array): PushWakeContent {
  const parsed: unknown = JSON.parse(utf8Decoder.decode(plaintext));
  if (!isRecord(parsed) || typeof parsed.paneId !== 'string' || parsed.paneId.length === 0) {
    throw new Error('push wake content: missing paneId');
  }
  return {
    paneId: parsed.paneId,
    worklaneId: typeof parsed.worklaneId === 'string' ? parsed.worklaneId : undefined,
    title: typeof parsed.title === 'string' ? parsed.title : '',
    body: typeof parsed.body === 'string' ? parsed.body : '',
  };
}

/**
 * Resolve a notification `data` payload to a {@link PushDeepLink} by deriving the
 * offline unseal key from the paired Mac's public key + this phone's identity
 * seed, opening the sealed content, and parsing it. Returns `undefined` when the
 * payload is not a recognizable wake for a known Mac, or when decryption/parsing
 * fails (a tampered or stale blob never crashes the app).
 */
export function resolvePushDeepLink(
  sodium: SodiumLike,
  params: {
    data: unknown;
    /** The phone's Ed25519 identity seed. */
    phoneIdentitySeed: Uint8Array;
    /** Look up a paired Mac's public key (base64url) by its device id. */
    macPublicKeyFor: (macDeviceId: string) => string | undefined;
  },
): PushDeepLink | undefined {
  const envelope = parsePushWakeEnvelope(params.data);
  if (!envelope) {
    return undefined;
  }
  const macPubKey = params.macPublicKeyFor(envelope.macDeviceId);
  if (!macPubKey) {
    return undefined;
  }
  try {
    const key = derivePushKey(sodium, {
      macIdentityPublicKey: decodeBase64Url(macPubKey),
      phoneIdentitySeed: params.phoneIdentitySeed,
    });
    const plaintext = unsealPush(sodium, key, decodeBase64Url(envelope.sealed));
    const content = parsePushWakeContent(plaintext);
    return { macDeviceId: envelope.macDeviceId, paneId: content.paneId, content };
  } catch {
    return undefined;
  }
}
