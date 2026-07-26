/**
 * App-wide constants for the Zentty mobile companion.
 *
 * The wire protocol version lives in @zentty/wire (see companion/wire);
 * everything here is mobile-only.
 */

/** URL scheme registered for deep links (app.json `scheme`). */
export const APP_SCHEME = 'zentty' as const;
