// Environment-driven relay configuration. Every knob has a safe default so the
// service runs with zero env set; overrides are read once at startup.

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
  logLevel: 'info',
};

function intEnv(
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === '') {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || !Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`invalid integer for ${key}: ${JSON.stringify(raw)}`);
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

/**
 * Build config from an environment map (defaults `process.env`). Recognized:
 * PORT, RATE_FRAMES_PER_SEC, RATE_BYTES_PER_SEC, RATE_PAIRING_PER_MIN,
 * RATE_MAX_FRAME_BYTES, RATE_MAX_PAIRING_SEALED_BYTES, LOG_LEVEL.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): RelayConfig {
  return {
    port: intEnv(env, 'PORT', DEFAULTS.port),
    framesPerSec: intEnv(env, 'RATE_FRAMES_PER_SEC', DEFAULTS.framesPerSec),
    bytesPerSec: intEnv(env, 'RATE_BYTES_PER_SEC', DEFAULTS.bytesPerSec),
    pairingPerMin: intEnv(env, 'RATE_PAIRING_PER_MIN', DEFAULTS.pairingPerMin),
    maxFrameBytes: intEnv(env, 'RATE_MAX_FRAME_BYTES', DEFAULTS.maxFrameBytes),
    maxPairingSealedBytes: intEnv(
      env,
      'RATE_MAX_PAIRING_SEALED_BYTES',
      DEFAULTS.maxPairingSealedBytes,
    ),
    logLevel: logLevelEnv(env, DEFAULTS.logLevel),
  };
}
