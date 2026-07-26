import { z } from 'zod';
import { LanHint, VersionRange } from '../types';

// session.* — handshake, keepalive, and error reporting inside the encrypted
// channel.

/** Both ways, first encrypted frame. Advertises the version window. */
export const SessionHello = z.object({
  supported: VersionRange,
  deviceName: z.string(),
  appVersion: z.string(),
});

/**
 * Effective negotiated version, plus the mac's CURRENT direct-LAN endpoint.
 *
 * `lanHint` makes the phone's cached endpoint self-healing. The phone stores a
 * hint at pairing time and dials it on every reconnect; if the mac is renamed or
 * its listener lands on a different port, that cached hint goes stale and direct
 * connection is dead until the user re-pairs. Restating it on every successful
 * handshake means ANY working path — direct or relay — refreshes the cache for
 * next time.
 *
 * Absent when the mac has no LAN listener (the feature is off, or the listener
 * failed to bind). An absent hint does NOT mean "forget the one you have": the
 * phone keeps its cached value, since a mac reachable only over the relay right
 * now may still be reachable directly later.
 */
export const SessionReady = z.object({
  v: z.number().int(),
  lanHint: LanHint.optional(),
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
