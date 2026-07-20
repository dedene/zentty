import { z } from 'zod';

// relay.* — the plaintext framing spoken between a device and the relay server.
//
// These frames are NOT the end-to-end `{v, id, type, payload}` envelope: they
// are the transport handshake and routing layer the relay itself reads. The
// relay never inspects the E2E `sealed` blob a `relay.frame` carries (the one
// documented exception is the pairing-window rate rule, which peeks only to
// classify plaintext `pairing.*` bootstrap frames — see the relay package).
//
// Wire shape: one flat JSON object per WebSocket message, discriminated by
// `type`. Unknown extra fields are stripped (forward compat), mirroring the
// envelope registry.

/**
 * Unpadded base64url (RFC 4648 §5). Used for the challenge nonce, the raw
 * 32-byte Ed25519 public key, the signature, the device id (which is itself
 * base64url(pubKey)), and the opaque `sealed` payload.
 */
export const Base64Url = z
  .string()
  .min(1)
  .regex(/^[A-Za-z0-9_-]+$/, 'must be unpadded base64url');

/** relay.challenge (relay -> device, on connect). */
export const RelayChallenge = z.object({
  type: z.literal('relay.challenge'),
  nonce: Base64Url,
  ts: z.number().int(),
});
export type RelayChallenge = z.infer<typeof RelayChallenge>;

/**
 * relay.auth (device -> relay). `sig` is Ed25519 over the UTF-8 bytes of
 * `"zentty-relay-auth:" + nonce` (the base64url nonce string as transmitted).
 * The relay verifies `deviceId === base64url(pubKey)` and the signature.
 */
export const RelayAuth = z.object({
  type: z.literal('relay.auth'),
  deviceId: Base64Url,
  pubKey: Base64Url,
  sig: Base64Url,
});
export type RelayAuth = z.infer<typeof RelayAuth>;

/** relay.ready (relay -> device): auth accepted. */
export const RelayReady = z.object({
  type: z.literal('relay.ready'),
  deviceId: Base64Url,
});
export type RelayReady = z.infer<typeof RelayReady>;

/** relay.denied (relay -> device): auth rejected; the connection then closes. */
export const RelayDenied = z.object({
  type: z.literal('relay.denied'),
  reason: z.string(),
});
export type RelayDenied = z.infer<typeof RelayDenied>;

/**
 * relay.frame (both ways). The relay stamps/overwrites `from` with the
 * authenticated sender before forwarding; devices cannot spoof it.
 */
export const RelayFrame = z.object({
  type: z.literal('relay.frame'),
  to: Base64Url,
  from: Base64Url,
  sealed: Base64Url,
});
export type RelayFrame = z.infer<typeof RelayFrame>;

/** relay.peerStatus (relay -> device): sent on subscribe and on changes. */
export const RelayPeerStatus = z.object({
  type: z.literal('relay.peerStatus'),
  deviceId: Base64Url,
  online: z.boolean(),
});
export type RelayPeerStatus = z.infer<typeof RelayPeerStatus>;

/** relay.watch (device -> relay): explicit subscription to a peer's status. */
export const RelayWatch = z.object({
  type: z.literal('relay.watch'),
  deviceId: Base64Url,
});
export type RelayWatch = z.infer<typeof RelayWatch>;

/** The closed set of relay error codes. */
export const RELAY_ERROR_CODES = [
  'rate_limited',
  'peer_unknown',
  'frame_too_large',
  'not_authed',
] as const;
export const RelayErrorCode = z.enum(RELAY_ERROR_CODES);
export type RelayErrorCode = z.infer<typeof RelayErrorCode>;

/** relay.error (relay -> device). */
export const RelayError = z.object({
  type: z.literal('relay.error'),
  code: RelayErrorCode,
  message: z.string(),
});
export type RelayError = z.infer<typeof RelayError>;

/**
 * The registry: `"relay.name"` -> frame schema. Canonical enumeration of every
 * relay-transport frame, mirroring MESSAGE_SCHEMAS for the envelope layer.
 */
export const RELAY_FRAME = {
  'relay.challenge': RelayChallenge,
  'relay.auth': RelayAuth,
  'relay.ready': RelayReady,
  'relay.denied': RelayDenied,
  'relay.frame': RelayFrame,
  'relay.peerStatus': RelayPeerStatus,
  'relay.watch': RelayWatch,
  'relay.error': RelayError,
} as const;

export type RelayFrameType = keyof typeof RELAY_FRAME;

/** All registered relay frame type strings, for coverage checks. */
export const RELAY_FRAME_TYPES = Object.keys(RELAY_FRAME) as RelayFrameType[];

/** Discriminated union over every relay frame, for one-shot parsing. */
export const RelayFrameSchema = z.discriminatedUnion('type', [
  RelayChallenge,
  RelayAuth,
  RelayReady,
  RelayDenied,
  RelayFrame,
  RelayPeerStatus,
  RelayWatch,
  RelayError,
]);
export type AnyRelayFrame = z.infer<typeof RelayFrameSchema>;

/** Raised when a relay frame carries a `type` outside {@link RELAY_FRAME}. */
export class UnknownRelayFrameError extends Error {
  readonly code = 'unknown_relay_frame';
  readonly type: string;
  constructor(type: string) {
    super(`unknown_relay_frame: ${type}`);
    this.name = 'UnknownRelayFrameError';
    this.type = type;
  }
}

/**
 * Validate an incoming relay frame end to end: parse JSON (if a string), then
 * validate against the discriminated union. Throws {@link UnknownRelayFrameError}
 * for an unregistered `type` and `ZodError` for a schema violation.
 */
export function parseRelayFrame(input: string | unknown): AnyRelayFrame {
  const raw: unknown = typeof input === 'string' ? JSON.parse(input) : input;
  if (raw !== null && typeof raw === 'object') {
    const type = (raw as Record<string, unknown>).type;
    if (typeof type === 'string' && !(type in RELAY_FRAME)) {
      throw new UnknownRelayFrameError(type);
    }
  }
  return RelayFrameSchema.parse(raw);
}

export type SafeRelayFrameResult =
  | { success: true; frame: AnyRelayFrame }
  | { success: false; error: Error };

/** Non-throwing variant of {@link parseRelayFrame}. */
export function safeParseRelayFrame(input: string | unknown): SafeRelayFrameResult {
  try {
    return { success: true, frame: parseRelayFrame(input) };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error : new Error(String(error)),
    };
  }
}
