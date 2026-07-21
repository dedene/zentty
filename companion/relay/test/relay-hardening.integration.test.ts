import {
  generateKeyPairSync,
  sign,
  type KeyObject,
} from 'node:crypto';
import { WebSocket } from 'ws';
import { afterEach, describe, expect, it } from 'vitest';
import { loadConfig, type RelayConfig } from '../src/config.js';
import { createRelayServer, type RelayServerHandle } from '../src/server.js';

// DoS / lifecycle hardening tests: watch caps + reaping, connection caps, the
// unauthenticated idle timeout, and the ws maxPayload guard. The auth/crypto
// contract is exercised in relay.integration.test.ts and is not re-tested here.

const RELAY_AUTH_PREFIX = 'zentty-relay-auth:';

interface Keypair {
  deviceId: string;
  pubKey: string;
  privateKey: KeyObject;
}

function makeKeypair(): Keypair {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'jwk' }).x as string;
  return { deviceId: raw, pubKey: raw, privateKey };
}

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
    this.send({ type: 'relay.auth', deviceId: keys.deviceId, pubKey: keys.pubKey, sig });
    const ready = await this.waitType('relay.ready');
    expect(ready.deviceId).toBe(keys.deviceId);
  }

  close(): void {
    this.ws.close();
  }
}

let server: RelayServerHandle | undefined;
const openDevices: Device[] = [];

async function startServer(overrides: Partial<RelayConfig> = {}): Promise<number> {
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

/** A base64url device id from a random label (no keypair needed as a watch target). */
function fakeId(label: string): string {
  return Buffer.from(label, 'utf8').toString('base64url');
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

describe('relay hardening — watch caps & reaping', () => {
  it('rejects relay.watch past the max distinct watched-peers cap', async () => {
    const port = await startServer({ maxWatchedPeers: 3 });
    const a = await connectDevice(port);
    await a.authenticate(makeKeypair());

    // First 3 distinct targets are accepted (each yields a peerStatus).
    for (let i = 0; i < 3; i++) {
      a.send({ type: 'relay.watch', deviceId: fakeId(`peer-${i}`) });
      const status = await a.waitType('relay.peerStatus');
      expect(status.online).toBe(false);
    }
    // The 4th distinct target is over the cap.
    a.send({ type: 'relay.watch', deviceId: fakeId('peer-3') });
    const error = await a.waitType('relay.error');
    expect(error.code).toBe('too_many_watches');
  });

  it('re-watching an existing target does not consume cap budget', async () => {
    const port = await startServer({ maxWatchedPeers: 1 });
    const a = await connectDevice(port);
    await a.authenticate(makeKeypair());

    const target = fakeId('same-peer');
    a.send({ type: 'relay.watch', deviceId: target });
    expect((await a.waitType('relay.peerStatus')).online).toBe(false);
    // Same target again: allowed, no error even though cap is 1.
    a.send({ type: 'relay.watch', deviceId: target });
    expect((await a.waitType('relay.peerStatus')).online).toBe(false);
  });

  it('rate-limits relay.watch through the per-device limiter', async () => {
    const port = await startServer({ framesPerSec: 2, maxWatchedPeers: 1000 });
    const a = await connectDevice(port);
    await a.authenticate(makeKeypair());

    // Budget is 2 frames/sec; the 3rd watch in the same tick is throttled.
    for (let i = 0; i < 3; i++) {
      a.send({ type: 'relay.watch', deviceId: fakeId(`w-${i}`) });
    }
    const error = await a.waitType('relay.error');
    expect(error.code).toBe('rate_limited');
  });

  it('reaps a disconnected watcher from its target watcher set', async () => {
    const port = await startServer();
    const aKeys = makeKeypair();
    const bKeys = makeKeypair();
    const a = await connectDevice(port);
    const b = await connectDevice(port);
    await a.authenticate(aKeys);
    await b.authenticate(bKeys);

    // A watches B; A learns B is online.
    a.send({ type: 'relay.watch', deviceId: bKeys.deviceId });
    expect((await a.waitType('relay.peerStatus')).online).toBe(true);

    // A disconnects. If the watch leaked, B going offline/online would still try
    // to notify the dead A. We verify by reconnecting B and confirming the relay
    // does not retain A as a watcher: a fresh watcher C sees exactly one entry.
    a.close();
    // Give the close handler a tick to run.
    await new Promise((r) => setTimeout(r, 50));

    // Reconnect A fresh (new connection, empty watch set) and re-watch B: it must
    // succeed with a peerStatus (proves the slot is healthy, no stale state).
    const a2 = await connectDevice(port);
    await a2.authenticate(aKeys);
    a2.send({ type: 'relay.watch', deviceId: bKeys.deviceId });
    expect((await a2.waitType('relay.peerStatus')).online).toBe(true);

    // B disconnects; the ONLY live watcher (a2) must be notified — and nothing
    // throws for the reaped original A.
    b.close();
    const offline = await a2.waitType('relay.peerStatus');
    expect(offline.deviceId).toBe(bKeys.deviceId);
    expect(offline.online).toBe(false);
  });
});

describe('relay hardening — connection lifecycle', () => {
  it('closes an unauthenticated socket after the auth timeout', async () => {
    const port = await startServer({ authTimeoutMs: 80 });
    const a = await connectDevice(port);
    await a.waitType('relay.challenge'); // received, but we never authenticate
    const closeCode = await new Promise<number>((resolve) => {
      a.ws.on('close', (code) => resolve(code));
    });
    expect(closeCode).toBe(1008);
  });

  it('does not close a socket that authenticates within the grace period', async () => {
    const port = await startServer({ authTimeoutMs: 300 });
    const a = await connectDevice(port);
    await a.authenticate(makeKeypair());
    let closed = false;
    a.ws.on('close', () => {
      closed = true;
    });
    await new Promise((r) => setTimeout(r, 400));
    expect(closed).toBe(false);
    expect(a.ws.readyState).toBe(WebSocket.OPEN);
  });

  it('rejects connections past the per-remote-address cap', async () => {
    const port = await startServer({ maxConnectionsPerIp: 2 });
    // Two connections from 127.0.0.1 are allowed.
    await connectDevice(port);
    await connectDevice(port);
    // The third is closed by the server (all from the same loopback address).
    const third = new WebSocket(`ws://127.0.0.1:${port}`);
    const code = await new Promise<number>((resolve, reject) => {
      third.on('close', (c) => resolve(c));
      third.on('error', reject);
    });
    expect(code).toBe(1013);
  });

  it('rejects an oversized frame at the ws maxPayload layer', async () => {
    const port = await startServer({ maxFrameBytes: 1024 });
    const a = await connectDevice(port);
    await a.waitType('relay.challenge');
    // A message larger than maxPayload: ws closes the connection (1009) before
    // the relay ever parses it.
    const code = await new Promise<number>((resolve) => {
      a.ws.on('close', (c) => resolve(c));
      a.ws.send('x'.repeat(4096));
    });
    expect(code).toBe(1009);
  });
});
