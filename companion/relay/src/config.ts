// Environment-driven relay configuration. Every knob has a safe default so the
// service runs with zero env set; overrides are read once at startup.

import { readFileSync } from 'node:fs';

export interface RelayConfig {
  /** TCP port for the HTTP/WebSocket listener. */
  port: number;
  /** Per-device sustained frame rate (token bucket capacity == 1s burst). */
  framesPerSec: number;
  /** Per-device sustained byte rate over relay.frame payloads. */
  bytesPerSec: number;
  /**
   * Pairing-window cap: frames whose `sealed` blob is a plaintext `pairing.*`
   * envelope are additionally metered here, per minute, per device. See
   * server.ts for why this is the relay-agnostic definition of "unknown peer".
   */
  pairingPerMin: number;
  /** Hard reject any single relay.frame larger than this (bytes on the wire). */
  maxFrameBytes: number;
  /** Hard cap on a plaintext pairing `sealed` payload (bytes, pre-base64). */
  maxPairingSealedBytes: number;
  /** Max distinct peers a single device may watch (explicit + implicit). */
  maxWatchedPeers: number;
  /** Global cap on concurrent WebSocket connections. */
  maxConnections: number;
  /** Per-remote-address cap on concurrent WebSocket connections. */
  maxConnectionsPerIp: number;
  /** Grace period (ms) to complete auth before an idle socket is closed. */
  authTimeoutMs: number;
  /** Per-socket outbound buffer cap (bytes); frames past it are dropped. */
  maxBufferedBytes: number;
  /**
   * Raw per-connection inbound message rate (msgs/sec, burst == this). A cheap
   * guard applied on every socket message BEFORE auth and independent of the
   * post-auth DeviceLimiter; a socket that exceeds it is closed.
   */
  maxMessagesPerSec: number;
  /**
   * Max distinct per-device rate limiters kept in memory (LRU-evicted past
   * this). Limiters are keyed by deviceId and survive reconnect so a client
   * cannot reset its throttle by dropping and re-authenticating.
   */
  maxDeviceLimiters: number;
  logLevel: LogLevel;
}

export type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'silent';

const LOG_LEVELS: readonly LogLevel[] = [
  'debug',
  'info',
  'warn',
  'error',
  'silent',
];

const DEFAULTS: RelayConfig = {
  port: 8080,
  framesPerSec: 50,
  bytesPerSec: 256 * 1024,
  pairingPerMin: 5,
  maxFrameBytes: 256 * 1024,
  maxPairingSealedBytes: 4 * 1024,
  maxWatchedPeers: 256,
  maxConnections: 10_000,
  maxConnectionsPerIp: 64,
  authTimeoutMs: 10_000,
  maxBufferedBytes: 4 * 1024 * 1024,
  maxMessagesPerSec: 250,
  maxDeviceLimiters: 10_000,
  logLevel: 'info',
};

/**
 * Parse an integer env var, clamped to [min, max]. A value outside the range —
 * including 0 where 0 would silently disable a protection — is a loud startup
 * error, matching the fail-fast style of the push-config loaders. Set min to 0
 * only for knobs where 0 is a real, safe value (e.g. PORT=0 == ephemeral port).
 */
function intEnv(
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === '') {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || !Number.isInteger(parsed)) {
    throw new Error(`invalid integer for ${key}: ${JSON.stringify(raw)}`);
  }
  if (parsed < min || parsed > max) {
    throw new Error(
      `${key} out of range: ${parsed} (expected ${min}..${max})`,
    );
  }
  return parsed;
}

function logLevelEnv(env: NodeJS.ProcessEnv, fallback: LogLevel): LogLevel {
  const raw = env.LOG_LEVEL;
  if (raw === undefined || raw.trim() === '') {
    return fallback;
  }
  const lowered = raw.trim().toLowerCase();
  if (!LOG_LEVELS.includes(lowered as LogLevel)) {
    throw new Error(
      `invalid LOG_LEVEL: ${JSON.stringify(raw)} (expected ${LOG_LEVELS.join('|')})`,
    );
  }
  return lowered as LogLevel;
}

// ---------------------------------------------------------------------------
// Push gateway configuration. Entirely separate from the relay transport config:
// resolving it reads files (the APNs .p8, the FCM service-account JSON), so it is
// loaded on its own and is optional. With no push env set, both platforms are
// undefined -> push is disabled and the relay still runs (sessions keep working;
// foregrounded apps still get live updates). Partial/misconfigured credentials
// are a loud startup error, never a silent half-enabled state.
// ---------------------------------------------------------------------------

export interface ApnsConfig {
  /** PEM contents of the APNs auth key (.p8), resolved from path or inline. */
  keyP8: string;
  keyId: string;
  teamId: string;
  /** APNs topic == the iOS bundle id. */
  topic: string;
  /** api.push.apple.com (production) or api.sandbox.push.apple.com. */
  host: string;
}

export interface FcmConfig {
  projectId: string;
  clientEmail: string;
  /** PEM private key from the service account. */
  privateKey: string;
  /** OAuth2 token endpoint from the service account (token_uri). */
  tokenUri: string;
}

export interface PushConfig {
  apns?: ApnsConfig;
  fcm?: FcmConfig;
  /** JSON token-store path; undefined -> in-memory (default; tests). */
  tokenStorePath?: string;
  /** Per-device wake burst (immediate tokens). */
  rateBurst: number;
  /** Per-device sustained wakes per minute. */
  ratePerMin: number;
  /** Max distinct rate-limit buckets kept in memory (LRU-evicted past this). */
  maxRateBuckets: number;
  /** Max distinct phones registered per Mac device id. */
  maxPhonesPerMac: number;
}

const DEFAULT_APNS_TOPIC = 'be.zenjoy.zentty.mobile';
const DEFAULT_APNS_HOST = 'api.push.apple.com';
const DEFAULT_FCM_TOKEN_URI = 'https://oauth2.googleapis.com/token';
const PUSH_DEFAULT_RATE_BURST = 5;
const PUSH_DEFAULT_RATE_PER_MIN = 10;
const PUSH_DEFAULT_MAX_RATE_BUCKETS = 10_000;
const PUSH_DEFAULT_MAX_PHONES_PER_MAC = 64;

function strEnv(env: NodeJS.ProcessEnv, key: string): string | undefined {
  const raw = env[key];
  return raw === undefined || raw.trim() === '' ? undefined : raw;
}

/** Resolve a credential given as either an inline PEM/JSON blob or a file path. */
function resolveMaybeFile(value: string, looksInline: (v: string) => boolean): string {
  if (looksInline(value)) {
    return value;
  }
  return readFileSync(value, 'utf8');
}

function loadApnsConfig(env: NodeJS.ProcessEnv): ApnsConfig | undefined {
  const keyRaw = strEnv(env, 'APNS_KEY_P8');
  const keyId = strEnv(env, 'APNS_KEY_ID');
  const teamId = strEnv(env, 'APNS_TEAM_ID');
  const present = [keyRaw, keyId, teamId].filter((v) => v !== undefined).length;
  if (present === 0) {
    return undefined;
  }
  if (present < 3) {
    throw new Error(
      'incomplete APNs config: set all of APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID (or none)',
    );
  }
  return {
    keyP8: resolveMaybeFile(keyRaw as string, (v) => v.includes('BEGIN')),
    keyId: keyId as string,
    teamId: teamId as string,
    topic: strEnv(env, 'APNS_TOPIC') ?? DEFAULT_APNS_TOPIC,
    host: strEnv(env, 'APNS_HOST') ?? DEFAULT_APNS_HOST,
  };
}

function loadFcmConfig(env: NodeJS.ProcessEnv): FcmConfig | undefined {
  const source = strEnv(env, 'FCM_SERVICE_ACCOUNT_JSON');
  if (source === undefined) {
    return undefined;
  }
  const rawJson = resolveMaybeFile(source, (v) => v.trimStart().startsWith('{'));
  const parsed = JSON.parse(rawJson) as {
    project_id?: string;
    client_email?: string;
    private_key?: string;
    token_uri?: string;
  };
  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error(
      'invalid FCM service account: need project_id, client_email, private_key',
    );
  }
  return {
    projectId: parsed.project_id,
    clientEmail: parsed.client_email,
    privateKey: parsed.private_key,
    tokenUri: parsed.token_uri ?? DEFAULT_FCM_TOKEN_URI,
  };
}

/**
 * Load push config from the environment. Recognized: APNS_KEY_P8 (path or inline
 * PEM), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, APNS_HOST, FCM_SERVICE_ACCOUNT_JSON
 * (path or inline JSON), PUSH_TOKEN_STORE, PUSH_RATE_BURST, PUSH_RATE_PER_MIN,
 * PUSH_MAX_RATE_BUCKETS, PUSH_MAX_PHONES_PER_MAC.
 * Reads credential files eagerly so a bad path fails fast at startup.
 */
export function loadPushConfig(env: NodeJS.ProcessEnv = process.env): PushConfig {
  const apns = loadApnsConfig(env);
  const fcm = loadFcmConfig(env);
  const tokenStorePath = strEnv(env, 'PUSH_TOKEN_STORE');
  return {
    ...(apns ? { apns } : {}),
    ...(fcm ? { fcm } : {}),
    ...(tokenStorePath !== undefined ? { tokenStorePath } : {}),
    rateBurst: intEnv(env, 'PUSH_RATE_BURST', PUSH_DEFAULT_RATE_BURST, 1, 1_000_000),
    ratePerMin: intEnv(
      env,
      'PUSH_RATE_PER_MIN',
      PUSH_DEFAULT_RATE_PER_MIN,
      1,
      1_000_000,
    ),
    maxRateBuckets: intEnv(
      env,
      'PUSH_MAX_RATE_BUCKETS',
      PUSH_DEFAULT_MAX_RATE_BUCKETS,
      1,
      10_000_000,
    ),
    maxPhonesPerMac: intEnv(
      env,
      'PUSH_MAX_PHONES_PER_MAC',
      PUSH_DEFAULT_MAX_PHONES_PER_MAC,
      1,
      1_000_000,
    ),
  };
}

/**
 * Build config from an environment map (defaults `process.env`). Recognized:
 * PORT, RATE_FRAMES_PER_SEC, RATE_BYTES_PER_SEC, RATE_PAIRING_PER_MIN,
 * RATE_MAX_FRAME_BYTES, RATE_MAX_PAIRING_SEALED_BYTES, MAX_WATCHED_PEERS,
 * MAX_CONNECTIONS, MAX_CONNECTIONS_PER_IP, AUTH_TIMEOUT_MS, MAX_BUFFERED_BYTES,
 * MAX_MESSAGES_PER_SEC, MAX_DEVICE_LIMITERS, LOG_LEVEL. Every numeric knob is
 * bounded so a misconfigured 0 (which would silently disable a protection) or an
 * absurd value fails loudly at startup.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): RelayConfig {
  return {
    // PORT 0 is a legitimate request for an OS-assigned ephemeral port.
    port: intEnv(env, 'PORT', DEFAULTS.port, 0, 65_535),
    framesPerSec: intEnv(env, 'RATE_FRAMES_PER_SEC', DEFAULTS.framesPerSec, 1, 1_000_000),
    bytesPerSec: intEnv(env, 'RATE_BYTES_PER_SEC', DEFAULTS.bytesPerSec, 1, 1_073_741_824),
    pairingPerMin: intEnv(env, 'RATE_PAIRING_PER_MIN', DEFAULTS.pairingPerMin, 1, 1_000_000),
    maxFrameBytes: intEnv(env, 'RATE_MAX_FRAME_BYTES', DEFAULTS.maxFrameBytes, 1, 67_108_864),
    maxPairingSealedBytes: intEnv(
      env,
      'RATE_MAX_PAIRING_SEALED_BYTES',
      DEFAULTS.maxPairingSealedBytes,
      1,
      67_108_864,
    ),
    maxWatchedPeers: intEnv(env, 'MAX_WATCHED_PEERS', DEFAULTS.maxWatchedPeers, 1, 10_000_000),
    maxConnections: intEnv(env, 'MAX_CONNECTIONS', DEFAULTS.maxConnections, 1, 10_000_000),
    maxConnectionsPerIp: intEnv(
      env,
      'MAX_CONNECTIONS_PER_IP',
      DEFAULTS.maxConnectionsPerIp,
      1,
      10_000_000,
    ),
    authTimeoutMs: intEnv(env, 'AUTH_TIMEOUT_MS', DEFAULTS.authTimeoutMs, 1, 3_600_000),
    maxBufferedBytes: intEnv(
      env,
      'MAX_BUFFERED_BYTES',
      DEFAULTS.maxBufferedBytes,
      1,
      1_073_741_824,
    ),
    maxMessagesPerSec: intEnv(
      env,
      'MAX_MESSAGES_PER_SEC',
      DEFAULTS.maxMessagesPerSec,
      1,
      10_000_000,
    ),
    maxDeviceLimiters: intEnv(
      env,
      'MAX_DEVICE_LIMITERS',
      DEFAULTS.maxDeviceLimiters,
      1,
      10_000_000,
    ),
    logLevel: logLevelEnv(env, DEFAULTS.logLevel),
  };
}
