import { z } from 'zod';
import { VersionRange } from '../types';

// session.* — handshake, keepalive, and error reporting inside the encrypted
// channel.

/** Both ways, first encrypted frame. Advertises the version window. */
export const SessionHello = z.object({
  supported: VersionRange,
  deviceName: z.string(),
  appVersion: z.string(),
});

/** Effective negotiated version. */
export const SessionReady = z.object({
  v: z.number().int(),
});

export const SessionPing = z.object({
  ts: z.number().int(),
});

export const SessionPong = z.object({
  ts: z.number().int(),
});

/** Emitted e.g. with code `unsupported_type` for an unknown envelope type. */
export const SessionError = z.object({
  code: z.string(),
  message: z.string(),
  fatal: z.boolean(),
});

export const sessionMessages = {
  'session.hello': SessionHello,
  'session.ready': SessionReady,
  'session.ping': SessionPing,
  'session.pong': SessionPong,
  'session.error': SessionError,
} as const;
