/**
 * App-wide constants for the Zentty mobile companion.
 *
 * The wire protocol version is the single value shared across the Mac bridge,
 * relay, and this app (see companion/wire). Everything else here is mobile-only.
 */

/** Protocol envelope version this build speaks. Mirrors @zentty/wire's PROTOCOL_VERSION. */
export const PROTOCOL_VERSION = 1 as const;

/** Human-facing app name, used in pairing frames as the phone's device name default. */
export const APP_NAME = 'Zentty' as const;

/** URL scheme registered for deep links (app.json `scheme`). */
export const APP_SCHEME = 'zentty' as const;

/** Bonjour service type the Mac bridge advertises for direct-LAN discovery. */
export const BONJOUR_SERVICE_TYPE = '_zentty._tcp' as const;
