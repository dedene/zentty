/** @jest-environment node */
import { beforeAll, describe, expect, it } from '@jest/globals';

import { loadSodium } from '../../../scripts/loadSodium';
import { decodeBase64Url, encodeBase64Url } from '../base64url';
import {
  Backoff,
  ConnectionFailedError,
  ConnectionManager,
  RELAY_AUTH_PREFIX,
  openRelayTransport,
} from '../connection';
import type { ConnectionStatus, TextSocket } from '../connection';
import { utf8Bytes } from '../crypto';
import type { TransportLike } from '../session';
import type { SodiumLike } from '../sodium';
import type { PairedMac } from '../storage';
import { makePhoneIdentity } from './harness';

const noopTransport = (): TransportLike => ({
  send: async () => undefined,
  receive: async () => null,
  close: () => undefined,
});

class ScriptedSocket implements TextSocket {
  readonly outbox: string[] = [];
  onSend?: (text: string, socket: ScriptedSocket) => void;
  private readonly queue: string[] = [];
  private readonly waiters: ((v: string | null) => void)[] = [];
  private closed = false;

  push(text: string): void {
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter(text);
    } else {
      this.queue.push(text);
    }
  }

  send(text: string): Promise<void> {
    this.outbox.push(text);
    this.onSend?.(text, this);
    return Promise.resolve();
  }

  receive(): Promise<string | null> {
    if (this.queue.length > 0) {
      return Promise.resolve(this.queue.shift() as string);
    }
    if (this.closed) {
      return Promise.resolve(null);
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  close(): void {
    this.closed = true;
    for (const w of this.waiters.splice(0)) {
      w(null);
    }
  }
}

describe('Backoff', () => {
  it('doubles the ceiling and resets', () => {
    const b = new Backoff({ base: 1000, cap: 60000, jitter: (c) => c });
    expect(b.next()).toBe(1000);
    expect(b.next()).toBe(2000);
    expect(b.next()).toBe(4000);
    b.reset();
    expect(b.next()).toBe(1000);
    expect(b.ceiling(10)).toBe(60000); // capped
  });
});

describe('openRelayTransport', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  it('authenticates with a valid signature, then tunnels frames to the Mac', async () => {
    const identity = makePhoneIdentity(sodium);
    const macDeviceId = 'mac-device-id';
    const nonce = encodeBase64Url(sodium.randomBytes(18));
    const socket = new ScriptedSocket();
    const peerStatuses: boolean[] = [];

    let auth: { type: string; deviceId: string; pubKey: string; sig: string } | undefined;
    socket.onSend = (text, s) => {
      const frame = JSON.parse(text) as { type: string };
      if (frame.type === 'relay.auth') {
        auth = frame as typeof auth;
        s.push(JSON.stringify({ type: 'relay.ready', deviceId: identity.deviceId }));
      }
    };
    socket.push(JSON.stringify({ type: 'relay.challenge', nonce, ts: 1 }));

    const transport = await openRelayTransport({
      socket,
      identity,
      sodium,
      macDeviceId,
      onPeerStatus: (online) => peerStatuses.push(online),
    });

    // The auth signature covers the UTF-8 of the prefix + the nonce string as
    // transmitted, verifiable against the phone's public key (== deviceId).
    expect(auth?.deviceId).toBe(identity.deviceId);
    expect(auth?.pubKey).toBe(identity.deviceId);
    const sigOk = sodium.signVerifyDetached(
      decodeBase64Url(auth?.sig as string),
      utf8Bytes(RELAY_AUTH_PREFIX + nonce),
      decodeBase64Url(identity.deviceId),
    );
    expect(sigOk).toBe(true);

    // Outbound bytes are wrapped as relay.frame to the Mac.
    await transport.send(new Uint8Array([1, 2, 3]));
    const sent = JSON.parse(socket.outbox[socket.outbox.length - 1]) as {
      type: string;
      to: string;
      from: string;
      sealed: string;
    };
    expect(sent.type).toBe('relay.frame');
    expect(sent.to).toBe(macDeviceId);
    expect(sent.from).toBe(identity.deviceId);
    expect(Array.from(decodeBase64Url(sent.sealed))).toEqual([1, 2, 3]);

    // A peerStatus for the Mac is surfaced; a following frame is delivered.
    socket.push(JSON.stringify({ type: 'relay.peerStatus', deviceId: macDeviceId, online: false }));
    socket.push(
      JSON.stringify({
        type: 'relay.frame',
        to: identity.deviceId,
        from: macDeviceId,
        sealed: encodeBase64Url(new Uint8Array([9, 8, 7])),
      }),
    );
    const received = await transport.receive();
    expect(Array.from(received as Uint8Array)).toEqual([9, 8, 7]);
    expect(peerStatuses).toEqual([false]);
  });

  it('rejects when the relay denies auth', async () => {
    const identity = makePhoneIdentity(sodium);
    const socket = new ScriptedSocket();
    socket.onSend = (text, s) => {
      if ((JSON.parse(text) as { type: string }).type === 'relay.auth') {
        s.push(JSON.stringify({ type: 'relay.denied', reason: 'peer_unknown' }));
      }
    };
    socket.push(JSON.stringify({ type: 'relay.challenge', nonce: encodeBase64Url(sodium.randomBytes(18)), ts: 1 }));
    await expect(
      openRelayTransport({ socket, identity, sodium, macDeviceId: 'm' }),
    ).rejects.toThrow(/relay denied/);
  });
});

describe('ConnectionManager', () => {
  const mac: PairedMac = {
    macDeviceId: 'mac-1',
    macPubKey: 'mac-1',
    macName: 'Studio',
    lanHint: { host: '192.168.1.10', port: 7777 },
    relayUrl: 'wss://relay/ws',
    pairedAt: 0,
  };

  it('prefers direct and does not touch relay when it succeeds', async () => {
    let relayCalls = 0;
    const statuses: ConnectionStatus[] = [];
    const cm = new ConnectionManager({
      mac,
      openDirect: async () => noopTransport(),
      openRelay: async () => {
        relayCalls += 1;
        return noopTransport();
      },
      onStatus: (s) => statuses.push(s),
    });
    const active = await cm.connectOnce();
    expect(active.kind).toBe('direct');
    expect(relayCalls).toBe(0);
    expect(statuses).toEqual([{ state: 'connecting' }, { state: 'connected', transport: 'direct' }]);
  });

  it('falls back to relay when direct fails', async () => {
    const statuses: ConnectionStatus[] = [];
    const cm = new ConnectionManager({
      mac,
      openDirect: async () => {
        throw new Error('no route to LAN host');
      },
      openRelay: async () => noopTransport(),
      onStatus: (s) => statuses.push(s),
    });
    const active = await cm.connectOnce();
    expect(active.kind).toBe('relay');
    expect(statuses).toEqual([{ state: 'connecting' }, { state: 'connected', transport: 'relay' }]);
  });

  it('falls back to relay when the direct attempt times out', async () => {
    const cm = new ConnectionManager({
      mac,
      openDirect: () => new Promise<TransportLike>(() => undefined), // never resolves
      openRelay: async () => noopTransport(),
      directTimeoutMs: 20,
    });
    const active = await cm.connectOnce();
    expect(active.kind).toBe('relay');
  });

  it('throws when both transports fail', async () => {
    const cm = new ConnectionManager({
      mac,
      openDirect: async () => {
        throw new Error('x');
      },
      openRelay: async () => {
        throw new Error('y');
      },
    });
    await expect(cm.connectOnce()).rejects.toBeInstanceOf(ConnectionFailedError);
  });

  it('retries with backoff, emitting offline, until a transport connects', async () => {
    let directCalls = 0;
    const statuses: ConnectionStatus[] = [];
    const cm = new ConnectionManager({
      mac,
      openDirect: async () => {
        directCalls += 1;
        if (directCalls < 3) {
          throw new Error('flaky');
        }
        return noopTransport();
      },
      openRelay: async () => {
        throw new Error('relay down');
      },
      onStatus: (s) => statuses.push(s),
      delay: async () => undefined, // collapse backoff waits
    });
    const active = await cm.connectWithRetry();
    expect(active.kind).toBe('direct');
    expect(directCalls).toBe(3);
    expect(statuses.filter((s) => s.state === 'offline')).toHaveLength(2);
  });
});
