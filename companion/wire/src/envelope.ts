import { z } from 'zod';

/**
 * Protocol version this build implements. The handshake negotiates the
 * effective version as min(maxA, maxB) and aborts if it drops below either
 * side's advertised minimum.
 */
export const PROTOCOL_VERSION = 1 as const;

/** Oldest protocol version this build can still speak. */
export const MIN_SUPPORTED = 1 as const;

/**
 * The transport-agnostic frame every message is wrapped in.
 *
 * `payload` is intentionally `unknown` at the envelope layer: it is re-validated
 * against the family schema keyed by `type` (see registry.ts). Unknown extra
 * fields are stripped rather than rejected, per the forward-compat rule.
 */
export const EnvelopeSchema = z.object({
  v: z.number().int(),
  id: z.string(),
  type: z.string(),
  replyTo: z.string().optional(),
  payload: z.unknown(),
});
export type Envelope = z.infer<typeof EnvelopeSchema>;
