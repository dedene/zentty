import { z } from 'zod';
import { LanHint } from '../types';

// pairing.* — plaintext bootstrap, one-time. Runs before the encrypted channel
// exists, so these are the only frames outside the sealed session.

/**
 * Carried inside the QR code, not sent on the wire. Schema exists so both sides
 * validate the decoded offer identically.
 */
export const PairingOffer = z.object({
  relayUrl: z.string(),
  lanHint: LanHint.optional(),
  macDeviceId: z.string(),
  macPubKey: z.string(),
  secret: z.string(),
  expiresAt: z.number().int(),
});

/** phone -> mac. `proof` = HMAC(secret, phonePubKey). */
export const PairingRequest = z.object({
  phoneDeviceId: z.string(),
  phonePubKey: z.string(),
  phoneName: z.string(),
  proof: z.string(),
});

/** mac -> phone, on success. */
export const PairingConfirm = z.object({
  macName: z.string(),
  paired: z.literal(true),
});

/** mac -> phone, on rejection. */
export const PairingReject = z.object({
  reason: z.string(),
});

export const pairingMessages = {
  'pairing.offer': PairingOffer,
  'pairing.request': PairingRequest,
  'pairing.confirm': PairingConfirm,
  'pairing.reject': PairingReject,
} as const;
