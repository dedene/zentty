import {
  generateKeyPairSync,
  sign,
  type KeyObject,
} from 'node:crypto';
import { WebSocket } from 'ws';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig, type RelayConfig } from '../src/config.js';
import { createRelayServer, type RelayServerHandle } from '../src/server.js';

// Integration tests: a real relay on an ephemeral port, driven by fake devices
// that generate genuine Ed25519 keypairs via node:crypto and complete the full
// challenge -> auth -> ready handshake.

const RELAY_AUTH_PREFIX = 'zentty-relay-auth:';

interface Keypair {
  deviceId: string;
  pubKey: string;
  privateKey: KeyObject;
}

function makeKeypair(): Keypair {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'jwk' }).x as string; // base64url raw
  return { deviceId: raw, pubKey: raw, privateKey };
}

/** A test client: buffers frames and lets tests await a frame by predicate. */
class Device {
  private readonly buffer: Record<string, unknown>[] = [];
  private readonly waiters: {
    match: (f: Record<string, unknown>) => boolean;
    resolve: (f: Record<string, unknown>) => void;
    reject: (e: Error) => void;
    timer: NodeJS.Timeout;
  }[] = [];

  private constructor(readonly ws: WebSocket) {
    ws.on('message', (raw) => {
      const frame = JSON.parse(raw.toString('utf8')) as Record<string, unknown>;
      const i = this.waiters.findIndex((w) => w.match(frame));
      if (i >= 0) {
        const [w] = this.waiters.splice(i, 1);
        clearTimeout(w!.timer);
        w!.resolve(frame);
      } else {
        this.buffer.push(frame);
      }
    });
  }

  static connect(port: number): Promise<Device> {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    return new Promise((resolve, reject) => {
      ws.once('open', () => resolve(new Device(ws)));
      ws.once('error', reject);
    });
  }

  wait(
    match: (f: Record<string, unknown>) => boolean,
    timeoutMs = 1500,
  ): Promise<Record<string, unknown>> {
    const i = this.buffer.findIndex(match);
    if (i >= 0) {
      const [f] = this.buffer.splice(i, 1);
      return Promise.resolve(f!);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error('timeout waiting for frame')),
        timeoutMs,
      );
      this.waiters.push({ match, resolve, reject, timer });
    });
  }

  waitType(type: string, timeoutMs?: number): Promise<Record<string, unknown>> {
    return this.wait((f) => f.type === type, timeoutMs);
  }

  send(frame: Record<string, unknown>): void {
    this.ws.send(JSON.stringify(frame));
  }

  async authenticate(keys: Keypair): Promise<void> {
    const challenge = await this.waitType('relay.challenge');
    const message = Buffer.from(
      RELAY_AUTH_PREFIX + (challenge.nonce as string),
      'utf8',
    );
    const sig = sign(null, message, keys.privateKey).toString('base64url');
    this.send({
      type: 'relay.auth',
      deviceId: keys.deviceId,
      pubKey: keys.pubKey,
      sig,
    });
    const ready = await this.waitType('relay.ready');
    expect(ready.deviceId).toBe(keys.deviceId);
  }

  close(): void {
    this.ws.close();
  }
}

let server: RelayServerHandle | undefined;
const openDevices: Device[] = [];

async function startServer(
  overrides: Partial<RelayConfig> = {},
): Promise<number> {
  const config: RelayConfig = {
    ...loadConfig({}),
    port: 0,
    logLevel: 'silent',
    ...overrides,
  };
  server = createRelayServer(config);
  return server.listen();
}

async function connectDevice(port: number): Promise<Device> {
  const device = await Device.connect(port);
  openDevices.push(device);
  return device;
}

afterEach(async () => {
  for (const d of openDevices.splice(0)) {
    d.close();
  }
  if (server) {
    await server.close();
    server = undefined;
  }
});

/** A base64url blob that is NOT a plaintext pairing envelope. */
function encryptedSealed(text = 'ciphertext'): string {
  return Buffer.from(text, 'utf8').toString('base64url');
}

describe('relay integration', () => {
  it('completes auth and routes a frame with enforced from-stamping', async () => {
    const port = await startServer();
    const aKeys = makeKeypair();
    const bKeys = makeKeypair();
    const a = await connectDevice(port);
    const b = await connectDevice(port);
    await a.authenticate(aKeys);
    await b.authenticate(bKeys);

    const sealed = encryptedSealed('hello-b');
    // Spoof `from`: the relay must overwrite it with the authenticated sender.
    a.send({
      type: 'relay.frame',
      to: bKeys.deviceId,
      from: 'Zm9yZ2VkLXNlbmRlcg', // "forged-sender", base64url
      sealed,
    });

    const routed = await b.waitType('relay.frame');
    expect(routed.to).toBe(bKeys.deviceId);
    expect(routed.from).toBe(aKeys.deviceId); // stamped, not the forged value
    expect(routed.from).not.toBe('Zm9yZ2VkLXNlbmRlcg');
    expect(routed.sealed).toBe(sealed);
  });

  it('reports peerStatus offline when the target is not connected', async () => {
    const port = await startServer();
    const aKeys = makeKeypair();
    const offlineKeys = makeKeypair();
    const a = await connectDevice(port);
    await a.authenticate(aKeys);

    a.send({
      type: 'relay.frame',
      to: offlineKeys.deviceId,
      from: aKeys.deviceId,
      sealed: encryptedSealed(),
    });

    const status = await a.waitType('relay.peerStatus');
    expect(status.deviceId).toBe(offlineKeys.deviceId);
    expect(status.online).toBe(false);
  });

  it('emits relay.error rate_limited past the frame budget', async () => {
    const port = await startServer({ framesPerSec: 2 });
    const aKeys = makeKeypair();
    const bKeys = makeKeypair();
    const a = await connectDevice(port);
    const b = await connectDevice(port);
    await a.authenticate(aKeys);
    await b.authenticate(bKeys);

    for (let i = 0; i < 3; i++) {
      a.send({
        type: 'relay.frame',
        to: bKeys.deviceId,
        from: aKeys.deviceId,
        sealed: encryptedSealed(`frame-${i}`),
      });
    }

    const error = await a.waitType('relay.error');
    expect(error.code).toBe('rate_limited');
  });

  it('rejects an oversized frame at the ws maxPayload layer (closes 1009)', async () => {
    // maxPayload == maxFrameBytes: an oversized frame is rejected by ws before it
    // is ever buffered or JSON.parsed, so the socket closes with 1009 ("message
    // too big") rather than routing an application-level relay.error.
    const port = await startServer({ maxFrameBytes: 512 });
    const aKeys = makeKeypair();
    const bKeys = makeKeypair();
    const a = await connectDevice(port);
    await a.authenticate(aKeys);

    const closeCode = await new Promise<number>((resolve) => {
      a.ws.on('close', (code) => resolve(code));
      a.send({
        type: 'relay.frame',
        to: bKeys.deviceId,
        from: aKeys.deviceId,
        sealed: 'A'.repeat(2000), // well over the 512-byte cap
      });
    });
    expect(closeCode).toBe(1009);
  });

  it('rejects a frame sent before authentication with not_authed', async () => {
    const port = await startServer();
    const bKeys = makeKeypair();
    const a = await connectDevice(port);
    // Consume the challenge but do NOT authenticate.
    await a.waitType('relay.challenge');

    a.send({
      type: 'relay.frame',
      to: bKeys.deviceId,
      from: 'Zm9yZ2Vk',
      sealed: encryptedSealed(),
    });

    const error = await a.waitType('relay.error');
    expect(error.code).toBe('not_authed');
  });

  it('serves /healthz over plain HTTP', async () => {
    const port = await startServer();
    const res = await fetch(`http://127.0.0.1:${port}/healthz`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('ok');
  });
});
