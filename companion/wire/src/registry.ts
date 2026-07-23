import type { z } from 'zod';
import { EnvelopeSchema } from './envelope';
import { pairingMessages } from './families/pairing';
import { sessionMessages } from './families/session';
import { dashboardMessages } from './families/dashboard';
import { paneMessages } from './families/pane';
import { inputMessages } from './families/input';
import { transcriptMessages } from './families/transcript';
import { leaseMessages } from './families/lease';
import { pushMessages } from './families/push';

/**
 * The registry: `"family.name"` type string -> payload schema. This is the
 * canonical enumeration of every wire message. Adding a family means spreading
 * its record in here.
 */
export const MESSAGE_SCHEMAS = {
  ...pairingMessages,
  ...sessionMessages,
  ...dashboardMessages,
  ...paneMessages,
  ...inputMessages,
  ...transcriptMessages,
  ...leaseMessages,
  ...pushMessages,
} as const;

export type MessageType = keyof typeof MESSAGE_SCHEMAS;

/** All registered type strings, for coverage checks and diagnostics. */
export const MESSAGE_TYPES = Object.keys(MESSAGE_SCHEMAS) as MessageType[];

/** Raised when an envelope carries a `type` outside the registry. */
export class UnknownTypeError extends Error {
  readonly code = 'unsupported_type';
  readonly type: string;
  constructor(type: string) {
    super(`unsupported_type: ${type}`);
    this.name = 'UnknownTypeError';
    this.type = type;
  }
}

export function getSchema(
  type: string,
): (typeof MESSAGE_SCHEMAS)[MessageType] | undefined {
  return (MESSAGE_SCHEMAS as Record<string, z.ZodType>)[type] as
    | (typeof MESSAGE_SCHEMAS)[MessageType]
    | undefined;
}

/** A fully validated frame: envelope fields plus a payload validated by type. */
export interface ParsedMessage {
  v: number;
  id: string;
  type: string;
  replyTo?: string;
  payload: unknown;
}

/**
 * Validate an incoming frame end to end: parse JSON (if a string), validate the
 * envelope, look up the payload schema by `type`, then validate the payload.
 *
 * Unknown extra fields are stripped (forward compat). Throws `UnknownTypeError`
 * for an unregistered type and `ZodError` for a schema violation.
 */
export function parseMessage(input: string | unknown): ParsedMessage {
  const raw: unknown = typeof input === 'string' ? JSON.parse(input) : input;
  const env = EnvelopeSchema.parse(raw);
  const schema = getSchema(env.type);
  if (!schema) {
    throw new UnknownTypeError(env.type);
  }
  const payload = schema.parse(env.payload);
  const message: ParsedMessage = {
    v: env.v,
    id: env.id,
    type: env.type,
    payload,
  };
  if (env.replyTo !== undefined) {
    message.replyTo = env.replyTo;
  }
  return message;
}

export type SafeParseResult =
  | { success: true; message: ParsedMessage }
  | { success: false; error: Error };

/** Non-throwing variant of {@link parseMessage}. */
export function safeParseMessage(input: string | unknown): SafeParseResult {
  try {
    return { success: true, message: parseMessage(input) };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error : new Error(String(error)),
    };
  }
}
