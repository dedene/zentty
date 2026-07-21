import {
  generateKeyPairSync,
  sign as nodeSign,
  type KeyObject,
} from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import {
  pushRegisterSigningString,
  pushWakeSigningString,
  type PushPlatform,
} from '@zentty/wire';
import { loadConfig } from '../src/config.js';
import type { ApnsConfig, FcmConfig, PushConfig } from '../src/config.js';
import { createLogger } from '../src/log.js';
import { createRelayServer, type RelayServerHandle } from '../src/server.js';
import { ApnsClient, type Http2Transport, type Http2Response } from '../src/push/apns.js';
import { FcmClient, type HttpsTransport, type HttpsResponse } from '../src/push/fcm.js';
import { PushRegistry } from '../src/push/registry.js';
import { createPushGateway, type PushGatewayDeps } from '../src/push/gateway.js';

// End-to-end gateway tests over a real HTTP server, with the APNs/FCM egress
// replaced by capturing transports. No Apple/Google endpoint is ever contacted.

const silent = createLogger('silent');

interface Mac {
  deviceId: string;
  privateKey: KeyObject;
}
function makeMac(): Mac {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { deviceId: publicKey.export({ format: 'jwk' }).x as string, privateKey };
}
function signWake(
  mac: Mac,
  f: { deviceId: string; token: string; platform: PushPlatform; sealedPayload: string },
): string {
  return nodeSign(null, Buffer.from(pushWakeSigningString(f), 'utf8'), mac.privateKey).toString(
    'base64url',
  );
}
function signRegister(
  mac: Mac,
  f: { macDeviceId: string; phoneDeviceId: string; platform: PushPlatform; token: string },
): string {
  return nodeSign(
    null,
    Buffer.from(pushRegisterSigningString(f), 'utf8'),
    mac.privateKey,
  ).toString('base64url');
}

// Test credentials — generated here, never real provider keys.
function testApnsConfig(): ApnsConfig {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  return {
    keyP8: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
    keyId: 'KEYID12345',
    teamId: 'TEAMID6789',
    topic: 'be.zenjoy.zentty.mobile',
    host: 'api.push.apple.com',
  };
}
function testFcmConfig(): FcmConfig {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  return {
    projectId: 'zentty-test',
    clientEmail: 'svc@zentty-test.iam.gserviceaccount.com',
    privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
    tokenUri: 'https://oauth2.googleapis.com/token',
  };
}

interface CapturedHttp2 {
  authority: string;
  headers: Record<string, string | number>;
  body: string;
}
function captureApns(response: Http2Response): {
  transport: Http2Transport;
  calls: CapturedHttp2[];
} {
  const calls: CapturedHttp2[] = [];
  return {
    calls,
    transport: {
      request(opts) {
        calls.push(opts);
        return Promise.resolve(response);
      },
    },
  };
}

interface CapturedHttps {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}
function captureFcm(responder: (call: CapturedHttps) => HttpsResponse): {
  transport: HttpsTransport;
  calls: CapturedHttps[];
} {
  const calls: CapturedHttps[] = [];
  return {
    calls,
    transport: {
      request(opts) {
        calls.push(opts);
        return Promise.resolve(responder(opts));
      },
    },
  };
}

const basePush: PushConfig = { rateBurst: 5, ratePerMin: 60 };

let server: RelayServerHandle | undefined;
async function start(pushConfig: PushConfig, deps: PushGatewayDeps): Promise<number> {
  const gateway = createPushGateway(pushConfig, silent, deps);
  server = createRelayServer({ ...loadConfig({}), port: 0, logLevel: 'silent' }, silent, gateway);
  return server.listen();
}
async function post(port: number, path: string, body: unknown): Promise<Response> {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

afterEach(async () => {
  if (server) {
    await server.close();
    server = undefined;
  }
});

describe('push gateway — APNs', () => {
  it('register then wake round-trips to 202 and shapes the APNs request', async () => {
    const registry = PushRegistry.open();
    const apnsCap = captureApns({ status: 200, headers: {}, body: '' });
    const apns = new ApnsClient(testApnsConfig(), silent, apnsCap.transport);
    const port = await start(basePush, { apns, registry });

    const mac = makeMac();
    const phoneId = 'phone-device-1';
    const token = 'apnstoken-abc123';

    const regRes = await post(port, '/register', {
      macDeviceId: mac.deviceId,
      phoneDeviceId: phoneId,
      platform: 'apns',
      token,
      sig: signRegister(mac, {
        macDeviceId: mac.deviceId,
        phoneDeviceId: phoneId,
        platform: 'apns',
        token,
      }),
    });
    expect(regRes.status).toBe(200);

    const sealedPayload = Buffer.from('cipher').toString('base64url');
    const wakeRes = await post(port, '/wake', {
      deviceId: phoneId,
      token,
      platform: 'apns',
      sealedPayload,
      sig: signWake(mac, { deviceId: phoneId, token, platform: 'apns', sealedPayload }),
    });
    expect(wakeRes.status).toBe(202);

    expect(apnsCap.calls).toHaveLength(1);
    const call = apnsCap.calls[0]!;
    expect(call.authority).toBe('https://api.push.apple.com');
    expect(call.headers[':method']).toBe('POST');
    expect(call.headers[':path']).toBe(`/3/device/${token}`);
    expect(call.headers['apns-topic']).toBe('be.zenjoy.zentty.mobile');
    expect(String(call.headers.authorization)).toMatch(/^bearer .+\..+\..+$/);
    const parsedBody = JSON.parse(call.body);
    expect(parsedBody.sealed).toBe(sealedPayload);
    expect(parsedBody.aps['mutable-content']).toBe(1);
  });

  it('rejects a wake signed by an unregistered mac with 401', async () => {
    const registry = PushRegistry.open();
    const apnsCap = captureApns({ status: 200, headers: {}, body: '' });
    const apns = new ApnsClient(testApnsConfig(), silent, apnsCap.transport);
    const port = await start(basePush, { apns, registry });

    const mac = makeMac();
    const attacker = makeMac();
    const phoneId = 'phone-1';
    const token = 'tok-1';
    registry.register({ macDeviceId: mac.deviceId, phoneDeviceId: phoneId, platform: 'apns', token });

    const sealedPayload = 'U0VBTEVE';
    const res = await post(port, '/wake', {
      deviceId: phoneId,
      token,
      platform: 'apns',
      sealedPayload,
      // Signed by the attacker, who is not the registered mac.
      sig: signWake(attacker, { deviceId: phoneId, token, platform: 'apns', sealedPayload }),
    });
    expect(res.status).toBe(401);
    expect(apnsCap.calls).toHaveLength(0);
  });

  it('rejects a garbage signature with 401 and never sends', async () => {
    const registry = PushRegistry.open();
    const apnsCap = captureApns({ status: 200, headers: {}, body: '' });
    const apns = new ApnsClient(testApnsConfig(), silent, apnsCap.transport);
    const port = await start(basePush, { apns, registry });
    const mac = makeMac();
    registry.register({ macDeviceId: mac.deviceId, phoneDeviceId: 'p', platform: 'apns', token: 't' });

    const res = await post(port, '/wake', {
      deviceId: 'p',
      token: 't',
      platform: 'apns',
      sealedPayload: 'U0VBTEVE',
      sig: 'not-a-real-signature',
    });
    expect(res.status).toBe(401);
    expect(apnsCap.calls).toHaveLength(0);
  });

  it('rejects a register with a bad signature with 401', async () => {
    const registry = PushRegistry.open();
    const apns = new ApnsClient(testApnsConfig(), silent, captureApns({ status: 200, headers: {}, body: '' }).transport);
    const port = await start(basePush, { apns, registry });
    const mac = makeMac();

    const res = await post(port, '/register', {
      macDeviceId: mac.deviceId,
      phoneDeviceId: 'p',
      platform: 'apns',
      token: 't',
      sig: 'wrong',
    });
    expect(res.status).toBe(401);
    expect(registry.size()).toBe(0);
  });

  it('maps an APNs rejection to 502 with the reason', async () => {
    const registry = PushRegistry.open();
    const apnsCap = captureApns({
      status: 400,
      headers: {},
      body: JSON.stringify({ reason: 'BadDeviceToken' }),
    });
    const apns = new ApnsClient(testApnsConfig(), silent, apnsCap.transport);
    const port = await start(basePush, { apns, registry });
    const mac = makeMac();
    registry.register({ macDeviceId: mac.deviceId, phoneDeviceId: 'p', platform: 'apns', token: 't' });

    const sealedPayload = 'U0VBTEVE';
    const res = await post(port, '/wake', {
      deviceId: 'p',
      token: 't',
      platform: 'apns',
      sealedPayload,
      sig: signWake(mac, { deviceId: 'p', token: 't', platform: 'apns', sealedPayload }),
    });
    expect(res.status).toBe(502);
    expect(((await res.json()) as { reason?: string }).reason).toBe('BadDeviceToken');
  });
});

describe('push gateway — FCM', () => {
  it('exchanges an OAuth2 token then shapes the FCM send request', async () => {
    const registry = PushRegistry.open();
    const fcmCap = captureFcm((call) =>
      call.url.endsWith('/token')
        ? { status: 200, body: JSON.stringify({ access_token: 'ya29.test', expires_in: 3600 }) }
        : { status: 200, body: JSON.stringify({ name: 'projects/zentty-test/messages/1' }) },
    );
    const fcm = new FcmClient(testFcmConfig(), silent, fcmCap.transport);
    const port = await start(basePush, { fcm, registry });

    const mac = makeMac();
    const phoneId = 'phone-fcm';
    const token = 'fcm-token-xyz';
    registry.register({ macDeviceId: mac.deviceId, phoneDeviceId: phoneId, platform: 'fcm', token });

    const sealedPayload = Buffer.from('cipher').toString('base64url');
    const res = await post(port, '/wake', {
      deviceId: phoneId,
      token,
      platform: 'fcm',
      sealedPayload,
      sig: signWake(mac, { deviceId: phoneId, token, platform: 'fcm', sealedPayload }),
    });
    expect(res.status).toBe(202);

    expect(fcmCap.calls).toHaveLength(2);
    const [tokenCall, sendCall] = fcmCap.calls;
    expect(tokenCall!.url).toBe('https://oauth2.googleapis.com/token');
    expect(tokenCall!.body).toContain('grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer');
    expect(sendCall!.url).toBe('https://fcm.googleapis.com/v1/projects/zentty-test/messages:send');
    expect(sendCall!.headers.authorization).toBe('Bearer ya29.test');
    const parsed = JSON.parse(sendCall!.body);
    expect(parsed.message.token).toBe(token);
    expect(parsed.message.data.sealed).toBe(sealedPayload);
  });
});

describe('push gateway — degradation & limits', () => {
  it('returns 503 (never throws) for a platform with no credentials', async () => {
    // Neither apns nor fcm configured -> disabled clients.
    const port = await start(basePush, {});
    const mac = makeMac();
    const sealedPayload = 'U0VBTEVE';
    const res = await post(port, '/wake', {
      deviceId: 'p',
      token: 't',
      platform: 'apns',
      sealedPayload,
      sig: signWake(mac, { deviceId: 'p', token: 't', platform: 'apns', sealedPayload }),
    });
    expect(res.status).toBe(503);
    expect(((await res.json()) as { error?: string }).error).toBe('platform_unconfigured');

    // /healthz still works — the relay is unaffected by push being off.
    const health = await fetch(`http://127.0.0.1:${port}/healthz`);
    expect(health.status).toBe(200);
  });

  it('throttles per-device wakes past the burst with 429', async () => {
    const registry = PushRegistry.open();
    const apnsCap = captureApns({ status: 200, headers: {}, body: '' });
    const apns = new ApnsClient(testApnsConfig(), silent, apnsCap.transport);
    // Frozen clock so the token bucket never refills during the test.
    const port = await start(
      { rateBurst: 2, ratePerMin: 60 },
      { apns, registry, now: () => 1_000 },
    );

    const mac = makeMac();
    const phoneId = 'phone-rl';
    const token = 'tok-rl';
    registry.register({ macDeviceId: mac.deviceId, phoneDeviceId: phoneId, platform: 'apns', token });

    const sealedPayload = 'U0VBTEVE';
    const wake = (): Promise<Response> =>
      post(port, '/wake', {
        deviceId: phoneId,
        token,
        platform: 'apns',
        sealedPayload,
        sig: signWake(mac, { deviceId: phoneId, token, platform: 'apns', sealedPayload }),
      });

    expect((await wake()).status).toBe(202);
    expect((await wake()).status).toBe(202);
    expect((await wake()).status).toBe(429);
  });
});
