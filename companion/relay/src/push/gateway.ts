import type { IncomingMessage, ServerResponse } from 'node:http';
import {
  PushRegisterRequest,
  PushWakeRequest,
  pushRegisterSigningString,
  pushWakeSigningString,
  type PushPlatform,
} from '@zentty/wire';
import type { PushConfig } from '../config.js';
import type { Logger } from '../log.js';
import { TokenBucket } from '../rateLimit.js';
import { ApnsClient } from './apns.js';
import { FcmClient } from './fcm.js';
import { PushRegistry } from './registry.js';
import { verifyEd25519 } from './signing.js';

// The push gateway: two Mac-authenticated REST endpoints bolted onto the relay's
// existing HTTP server.
//
//   POST /register  {macDeviceId, phoneDeviceId, platform, token, sig}
//   POST /wake      {deviceId, token, platform, sealedPayload, sig}
//
// Both are signed by the Mac's Ed25519 identity key over a canonical string from
// @zentty/wire, so the Mac signer and this verifier cannot drift. /wake carries
// only the phone side; the gateway looks up the mac(s) paired to that
// (phone, token, platform) and verifies the signature against each candidate key.
//
// Status contract:
//   202 accepted        wake handed to APNs/FCM
//   200 registered      token stored
//   400 bad request     unparseable / schema-invalid body
//   401 unauthorized    signature does not verify for any paired mac
//   404 not found       no registration matches the wake target
//   429 rate limited    per-device push budget exceeded
//   503 unavailable     that platform has no credentials configured
//   502 bad gateway     APNs/FCM accepted the request but rejected the push

/** Max request body the gateway will buffer (sealed payloads are small). */
const MAX_BODY_BYTES = 16 * 1024;

export interface PushGatewayDeps {
  apns?: ApnsClient;
  fcm?: FcmClient;
  registry?: PushRegistry;
  /** Injectable clock for the per-device rate limiter (tests). */
  now?: () => number;
}

export interface PushGateway {
  readonly apns: ApnsClient;
  readonly fcm: FcmClient;
  readonly registry: PushRegistry;
  /** Handle a request if its path is a push endpoint. Returns true if handled. */
  handleRequest(req: IncomingMessage, res: ServerResponse): Promise<boolean>;
}

export function createPushGateway(
  config: PushConfig,
  logger: Logger,
  deps: PushGatewayDeps = {},
): PushGateway {
  const apns = deps.apns ?? new ApnsClient(config.apns, logger);
  const fcm = deps.fcm ?? new FcmClient(config.fcm, logger);
  const registry = deps.registry ?? PushRegistry.open(config.tokenStorePath);
  const now = deps.now ?? Date.now;

  // Per-device token bucket: `burst` immediate, then `perMin`/60 sustained.
  // Attention pushes are human-scale (spec: >1/min sustained -> throttle).
  const buckets = new Map<string, TokenBucket>();
  function admit(deviceId: string): boolean {
    let bucket = buckets.get(deviceId);
    if (!bucket) {
      bucket = new TokenBucket(config.rateBurst, config.ratePerMin / 60, now);
      buckets.set(deviceId, bucket);
    }
    return bucket.take(1);
  }

  function enabledFor(platform: PushPlatform): boolean {
    return platform === 'apns' ? apns.isEnabled : fcm.isEnabled;
  }

  async function handleRegister(res: ServerResponse, body: string): Promise<void> {
    const parsed = PushRegisterRequest.safeParse(safeJson(body));
    if (!parsed.success) {
      return reply(res, 400, { error: 'invalid_request' });
    }
    const { macDeviceId, phoneDeviceId, platform, token, sig } = parsed.data;
    const message = Buffer.from(
      pushRegisterSigningString({ macDeviceId, phoneDeviceId, platform, token }),
      'utf8',
    );
    if (!verifyEd25519(macDeviceId, message, sig)) {
      logger.warn('push register: bad signature', { macDeviceId });
      return reply(res, 401, { error: 'unauthorized' });
    }
    registry.register({ macDeviceId, phoneDeviceId, platform, token });
    logger.info('push token registered', { macDeviceId, phoneDeviceId, platform });
    return reply(res, 200, { registered: true });
  }

  async function handleWake(res: ServerResponse, body: string): Promise<void> {
    const parsed = PushWakeRequest.safeParse(safeJson(body));
    if (!parsed.success) {
      return reply(res, 400, { error: 'invalid_request' });
    }
    const { deviceId, token, platform, sealedPayload, sig } = parsed.data;

    if (!enabledFor(platform)) {
      return reply(res, 503, { error: 'platform_unconfigured', platform });
    }
    if (!admit(deviceId)) {
      return reply(res, 429, { error: 'rate_limited' });
    }

    const candidates = registry.macsForWake(deviceId, token, platform);
    if (candidates.length === 0) {
      return reply(res, 404, { error: 'not_registered' });
    }
    const message = Buffer.from(
      pushWakeSigningString({ deviceId, token, platform, sealedPayload }),
      'utf8',
    );
    const authorized = candidates.some((mac) => verifyEd25519(mac, message, sig));
    if (!authorized) {
      logger.warn('push wake: bad signature', { deviceId, platform });
      return reply(res, 401, { error: 'unauthorized' });
    }

    const result =
      platform === 'apns'
        ? await apns.send(token, sealedPayload)
        : await fcm.send(token, sealedPayload);
    if (!result.accepted) {
      return reply(res, 502, {
        error: 'push_rejected',
        ...(result.reason ? { reason: result.reason } : {}),
      });
    }
    return reply(res, 202, { accepted: true });
  }

  return {
    apns,
    fcm,
    registry,
    async handleRequest(req, res): Promise<boolean> {
      const path = (req.url ?? '').split('?')[0];
      if (path !== '/register' && path !== '/wake') {
        return false;
      }
      if (req.method !== 'POST') {
        reply(res, 405, { error: 'method_not_allowed' });
        return true;
      }
      let body: string;
      try {
        body = await readBody(req);
      } catch (error) {
        logger.debug('push body read failed', {
          error: error instanceof Error ? error.message : String(error),
        });
        reply(res, 400, { error: 'invalid_body' });
        return true;
      }
      if (path === '/register') {
        await handleRegister(res, body);
      } else {
        await handleWake(res, body);
      }
      return true;
    },
  };
}

function reply(res: ServerResponse, status: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body);
}

function safeJson(body: string): unknown {
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}
