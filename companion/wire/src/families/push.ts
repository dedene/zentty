import { z } from 'zod';

// push.* — the push pipeline contract.
//
// Two distinct surfaces live here:
//   1. Device wire messages (`push.register`, `push.test`) — phone -> mac, inside
//      the E2E session envelope. The phone hands its APNs/FCM token to its Mac.
//   2. The push *gateway* REST contract (`/register`, `/wake`) — mac -> gateway,
//      plain HTTP, each request Ed25519-signed by the Mac's device identity key.
//      These are NOT envelope messages (no {v,id,type,payload}); they are request
//      bodies. Their canonical signing strings are defined here so the Mac signer,
//      the gateway verifier, and the tests all agree byte-for-byte.

export const PushPlatform = z.enum(['apns', 'fcm']);
export type PushPlatform = z.infer<typeof PushPlatform>;

/** phone -> mac (envelope). The mac forwards a signed registration to the gateway. */
export const PushRegister = z.object({
  platform: PushPlatform,
  token: z.string(),
  deviceId: z.string(),
});

/** phone -> mac (envelope). Requests a test notification. */
export const PushTest = z.object({});

export const pushMessages = {
  'push.register': PushRegister,
  'push.test': PushTest,
} as const;

// ---------------------------------------------------------------------------
// Gateway REST contract (mac -> gateway). Signed with the Mac's Ed25519 identity
// key; `deviceId` values are base64url(pubkey), so the gateway derives the
// verifying key straight from the id it already knows for the pairing.
// ---------------------------------------------------------------------------

/** Domain-separated, versioned prefixes so a wake sig can never verify as a register sig. */
export const PUSH_WAKE_SIGN_PREFIX = 'zentty-push-wake:v1';
export const PUSH_REGISTER_SIGN_PREFIX = 'zentty-push-register:v1';

/**
 * POST /register body. The Mac registers a phone's push token with the gateway,
 * binding it to the (macDeviceId, phoneDeviceId) pairing. `sig` is Ed25519 by the
 * Mac identity key over {@link pushRegisterSigningString}.
 */
export const PushRegisterRequest = z.object({
  macDeviceId: z.string().min(1),
  phoneDeviceId: z.string().min(1),
  platform: PushPlatform,
  token: z.string().min(1),
  sig: z.string().min(1),
});
export type PushRegisterRequest = z.infer<typeof PushRegisterRequest>;

/**
 * POST /wake body. The Mac asks the gateway to wake a paired phone. `deviceId` is
 * the *phone's* device id (the wake target); the gateway finds the mac(s) paired
 * to (deviceId, token, platform) and verifies `sig` against each candidate mac
 * key. `sig` is Ed25519 by the Mac identity key over {@link pushWakeSigningString}.
 * `sealedPayload` is the E2E-encrypted notification body, opaque to the gateway.
 */
export const PushWakeRequest = z.object({
  deviceId: z.string().min(1),
  token: z.string().min(1),
  platform: PushPlatform,
  sealedPayload: z.string().min(1),
  sig: z.string().min(1),
});
export type PushWakeRequest = z.infer<typeof PushWakeRequest>;

/** Fields of the wake signing string (the request minus `sig`). */
export interface PushWakeSignFields {
  deviceId: string;
  token: string;
  platform: PushPlatform;
  sealedPayload: string;
}

/** Fields of the register signing string (the request minus `sig`). */
export interface PushRegisterSignFields {
  macDeviceId: string;
  phoneDeviceId: string;
  platform: PushPlatform;
  token: string;
}

/**
 * Canonical bytes-to-sign for POST /wake. Deliberately explicit and
 * language-agnostic: a fixed prefix line, then the fields in alphabetical order
 * as `key=value` lines joined by `\n`, no trailing newline. Every value here is a
 * base64url id/token, a platform enum, or a base64 payload — none can contain a
 * newline, so the framing is unambiguous. The Swift signer MUST reproduce this
 * string byte-for-byte (UTF-8) before signing.
 */
export function pushWakeSigningString(fields: PushWakeSignFields): string {
  return [
    PUSH_WAKE_SIGN_PREFIX,
    `deviceId=${fields.deviceId}`,
    `platform=${fields.platform}`,
    `sealedPayload=${fields.sealedPayload}`,
    `token=${fields.token}`,
  ].join('\n');
}

/**
 * Canonical bytes-to-sign for POST /register. Same framing rules as
 * {@link pushWakeSigningString}: prefix line, then alphabetical `key=value` lines.
 */
export function pushRegisterSigningString(fields: PushRegisterSignFields): string {
  return [
    PUSH_REGISTER_SIGN_PREFIX,
    `macDeviceId=${fields.macDeviceId}`,
    `phoneDeviceId=${fields.phoneDeviceId}`,
    `platform=${fields.platform}`,
    `token=${fields.token}`,
  ].join('\n');
}
