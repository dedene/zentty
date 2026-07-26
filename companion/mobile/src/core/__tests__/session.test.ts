/** @jest-environment node */
import { beforeAll, describe, expect, it, jest } from '@jest/globals';
import type { ParsedMessage } from '@zentty/wire';

import { loadSodium } from '../../../scripts/loadSodium';
import { encodeBase64Url } from '../base64url';
import { utf8Bytes } from '../crypto';
import {
  HandshakeError,
  PairingRejectedError,
  PairingTimeoutError,
  PhoneSession,
  RemoteSessionError,
  RequestTimeoutError,
  VersionMismatchError,
  computePairingProof,
  parsePairingOffer,
  runPairing,
} from '../session';
import type { PairingOfferData, TransportLike } from '../session';
import type { SodiumLike } from '../sodium';
import { FakeMac, makePhoneIdentity, makePipe } from './harness';

const flush = async (): Promise<void> => {
  for (let i = 0; i < 5; i += 1) {
    await new Promise((r) => setTimeout(r, 0));
  }
};

const decoder = new TextDecoder();

describe('parsePairingOffer', () => {
  // The Mac encodes the QR/manual code as the full wire ENVELOPE, not a bare
  // payload: `{v, id, type: 'pairing.offer', payload}` with canonical sorted
  // keys (see CompanionEnvelope + MobileDevicesPairingViewModel.swift). The QR
  // carries this JSON verbatim; the manual fallback code is base64url of the
  // same bytes (CompanionBase64URL.encode). parsePairingOffer must unwrap the
  // envelope and return the flat payload the rest of the flow consumes.
  const OFFER = {
    relayUrl: 'wss://relay.example/ws',
    lanHint: { host: '192.168.1.20', port: 8_765 },
    macDeviceId: 'mac-device-id',
    macPubKey: 'mac-pub-key',
    secret: 'c2VjcmV0',
    expiresAt: 9_999_999_999_999,
  };
  const envelope = (payload: unknown, over: Record<string, unknown> = {}): string =>
    JSON.stringify({
      v: 1,
      id: '6f1b3d2a-9c47-4e18-8a52-1d7f0b6c3e94',
      type: 'pairing.offer',
      payload,
      ...over,
    });
  const OFFER_JSON = envelope(OFFER);
  const base64url = (json: string): string => encodeBase64Url(utf8Bytes(json));

  it('parses the raw JSON envelope offer (QR payload) to the flat payload', () => {
    expect(parsePairingOffer(OFFER_JSON)).toEqual(OFFER);
  });

  it('parses a base64url-encoded envelope offer to the same result as raw JSON', () => {
    expect(parsePairingOffer(base64url(OFFER_JSON))).toEqual(parsePairingOffer(OFFER_JSON));
  });

  it('parses a base64url code with wrapping whitespace and newlines', () => {
    const code = base64url(OFFER_JSON);
    // The phone's paste field is multiline: a long code wraps and can pick up
    // spaces/newlines around and inside the wrapped run.
    const mid = Math.floor(code.length / 2);
    const wrapped = `  ${code.slice(0, mid)}\n  ${code.slice(mid)}  \n`;
    expect(parsePairingOffer(wrapped)).toEqual(OFFER);
  });

  it('parses raw JSON with surrounding whitespace', () => {
    expect(parsePairingOffer(`\n  ${OFFER_JSON}\n`)).toEqual(OFFER);
  });

  it('tolerates a padded base64 spelling of the offer', () => {
    const code = base64url(OFFER_JSON);
    const padded = code + '='.repeat((4 - (code.length % 4)) % 4);
    expect(parsePairingOffer(padded)).toEqual(OFFER);
  });

  // Producer/consumer skew guard: a LITERAL canonical-JSON envelope with sorted
  // keys, exactly as the Mac emits it (id, payload, type, v — and inside the
  // payload expiresAt, lanHint, macDeviceId, macPubKey, relayUrl, secret). Not
  // built via the same JSON.stringify path the fixtures above use, so if the
  // consumer ever drifts from the Mac's canonical envelope shape this fails.
  it('parses the literal canonical-JSON envelope the Mac emits', () => {
    const canonical =
      '{"id":"6f1b3d2a-9c47-4e18-8a52-1d7f0b6c3e94",' +
      '"payload":{"expiresAt":9999999999999,' +
      '"lanHint":{"host":"192.168.1.20","port":8765},' +
      '"macDeviceId":"mac-device-id","macPubKey":"mac-pub-key",' +
      '"relayUrl":"wss://relay.example/ws","secret":"c2VjcmV0"},' +
      '"type":"pairing.offer","v":1}';
    expect(parsePairingOffer(canonical)).toEqual(OFFER);
    expect(parsePairingOffer(base64url(canonical))).toEqual(OFFER);
  });

  it('throws on garbage input', () => {
    expect(() => parsePairingOffer('not a zentty code!')).toThrow();
  });

  it('throws on a bare flat payload without the wire envelope', () => {
    // The original bug shipped a flat payload through the envelope schema. A
    // payload missing v/id/type is not a valid envelope and must be rejected.
    expect(() => parsePairingOffer(JSON.stringify(OFFER))).toThrow();
  });

  it('throws on an envelope whose payload is not a valid offer', () => {
    const { macPubKey: _dropped, ...incomplete } = OFFER;
    expect(() => parsePairingOffer(envelope(incomplete))).toThrow();
  });

  it('throws on an envelope carrying a non-pairing.offer type', () => {
    expect(() => parsePairingOffer(envelope(OFFER, { type: 'session.ping' }))).toThrow();
  });

  it('throws on an envelope with an incompatible protocol version', () => {
    expect(() => parsePairingOffer(envelope(OFFER, { v: 2 }))).toThrow();
  });

  it('throws on base64url that does not decode to a valid offer envelope', () => {
    expect(() => parsePairingOffer(base64url('{"nope":true}'))).toThrow();
  });
});

describe('runPairing', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  function makeOffer(secret: Uint8Array): PairingOfferData {
    return {
      relayUrl: 'wss://relay.example/ws',
      macDeviceId: 'mac-device-id',
      macPubKey: 'mac-pub-key',
      secret: encodeBase64Url(secret),
      expiresAt: 9_999_999_999_999,
    };
  }

  it('sends a valid proof and resolves the paired Mac on confirm', async () => {
    const identity = makePhoneIdentity(sodium);
    const secret = sodium.randomBytes(32);
    const offer = makeOffer(secret);
    const [phoneT, macT] = makePipe();

    const macSide = (async () => {
      const frame = await macT.receive();
      const env = JSON.parse(decoder.decode(frame as Uint8Array)) as {
        type: string;
        payload: { phonePubKey: string; proof: string; phoneName: string };
      };
      expect(env.type).toBe('pairing.request');
      // The Mac verifies proof = HMAC(secret, rawPhonePubKey); recomputing it here
      // is exactly CompanionPairingStore.verifyPairingProof.
      expect(env.payload.proof).toBe(computePairingProof(offer.secret, identity.publicKey));
      await macT.send(
        utf8Bytes(
          JSON.stringify({
            v: 1,
            id: 'mac-confirm',
            type: 'pairing.confirm',
            payload: { macName: 'Studio', paired: true },
          }),
        ),
      );
    })();

    const paired = await runPairing({
      transport: phoneT,
      offer,
      identity,
      phoneName: 'iPhone',
      sodium,
      now: () => 1234,
    });
    await macSide;

    expect(paired.macDeviceId).toBe('mac-device-id');
    expect(paired.macName).toBe('Studio');
    expect(paired.relayUrl).toBe('wss://relay.example/ws');
    expect(paired.pairedAt).toBe(1234);
  });

  it('throws PairingRejectedError on reject', async () => {
    const identity = makePhoneIdentity(sodium);
    const offer = makeOffer(sodium.randomBytes(32));
    const [phoneT, macT] = makePipe();

    void (async () => {
      await macT.receive();
      await macT.send(
        utf8Bytes(
          JSON.stringify({
            v: 1,
            id: 'mac-reject',
            type: 'pairing.reject',
            payload: { reason: 'invalid_proof' },
          }),
        ),
      );
    })();

    await expect(
      runPairing({ transport: phoneT, offer, identity, phoneName: 'iPhone', sodium }),
    ).rejects.toBeInstanceOf(PairingRejectedError);
  });

  it('times out when the peer accepts the socket but never replies', async () => {
    jest.useFakeTimers();
    try {
      const identity = makePhoneIdentity(sodium);
      const offer = makeOffer(sodium.randomBytes(32));
      // Nobody reads the other end: the request is delivered but never answered.
      const [phoneT] = makePipe();

      const pairP = runPairing({
        transport: phoneT,
        offer,
        identity,
        phoneName: 'iPhone',
        sodium,
        timeoutMs: 10_000,
      });
      const assertion = expect(pairP).rejects.toBeInstanceOf(PairingTimeoutError);

      await jest.advanceTimersByTimeAsync(10_000);
      await assertion;
      phoneT.close();
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('PhoneSession', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  function wire(options?: {
    versionMismatch?: boolean;
    stallReady?: boolean;
    handshakeTimeoutMs?: number;
    requestTimeoutMs?: number;
    afterReady?: (mac: FakeMac) => void;
    macOnMessage?: (message: { type: string; id: string; payload: unknown }) => void;
  }) {
    const identity = makePhoneIdentity(sodium);
    const macSeed = sodium.randomBytes(32);
    const [phoneT, macT] = makePipe();
    const inbox: ParsedMessage[] = [];
    const frameErrors: Error[] = [];
    const mac = new FakeMac({
      transport: macT,
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
      versionMismatch: options?.versionMismatch,
      stallReady: options?.stallReady,
      afterReady: options?.afterReady,
      onMessage: options?.macOnMessage,
    });
    const session = new PhoneSession({
      transport: phoneT,
      identity,
      mac: mac.pairedRecord({ relayUrl: 'wss://r/ws' }),
      sodium,
      deviceName: 'iPhone',
      appVersion: '1.0.0',
      handshakeTimeoutMs: options?.handshakeTimeoutMs,
      requestTimeoutMs: options?.requestTimeoutMs,
      onMessage: (m) => inbox.push(m),
      onFrameError: (e) => frameErrors.push(e),
    });
    return { session, mac, inbox, frameErrors };
  }

  it('completes the handshake, negotiates v1, and answers a ping', async () => {
    const { session, mac, inbox } = wire();
    const macRun = mac.run();

    await session.connect();
    expect(session.state).toBe('ready');
    expect(session.negotiatedVersion).toBe(1);

    const reply = await session.request('session.ping', { ts: 42 });
    expect(reply.type).toBe('session.pong');
    expect((reply.payload as { ts: number }).ts).toBe(42);

    // An unsolicited (no replyTo) frame is routed to onMessage.
    mac.sendSealed('session.ping', { ts: 7 });
    await flush();
    expect(inbox.some((m) => m.type === 'session.ping')).toBe(true);

    session.close();
    await macRun;
  });

  it('times out and closes the session when session.ready never arrives', async () => {
    jest.useFakeTimers();
    try {
      // The relay/socket is up and the crypto handshake completes, but the Mac
      // never sends session.ready — without a deadline connect() would hang forever.
      const { session, mac } = wire({ stallReady: true, handshakeTimeoutMs: 10_000 });
      const macRun = mac.run().catch(() => undefined);
      const connectP = session.connect();
      const assertion = expect(connectP).rejects.toBeInstanceOf(HandshakeError);

      // Let the handshake microtasks settle, then trip the 10s deadline.
      await jest.advanceTimersByTimeAsync(10_000);
      await assertion;
      expect(session.state).toBe('closed');
      await macRun;
    } finally {
      jest.useRealTimers();
    }
  });

  it('rejects connect with VersionMismatchError on an incompatible peer', async () => {
    const { session, mac } = wire({ versionMismatch: true });
    const macRun = mac.run();
    await expect(session.connect()).rejects.toBeInstanceOf(VersionMismatchError);
    expect(session.state).toBe('closed');
    await macRun;
  });

  it('drops a replayed frame without surfacing it twice', async () => {
    let replayFrame: Uint8Array | undefined;
    const { session, mac, inbox, frameErrors } = wire({
      afterReady: (m) => {
        replayFrame = m.seal('session.ping', { ts: 1 });
        m.sendRaw(replayFrame);
        m.sendRaw(replayFrame); // identical bytes -> stale counter on the second
      },
    });
    const macRun = mac.run();

    await session.connect();
    await flush();

    const pings = inbox.filter((msg) => msg.type === 'session.ping');
    expect(pings).toHaveLength(1);
    expect(frameErrors).toHaveLength(1);
    expect((frameErrors[0] as { code?: string }).code).toBe('replayDetected');

    session.close();
    await macRun;
  });

  it('rejects an unanswered request on timeout and drops the late reply', async () => {
    // The Mac receives the request but never answers (relay dropped the frame).
    let requestId: string | undefined;
    const { session, mac, inbox } = wire({
      requestTimeoutMs: 5_000,
      macOnMessage: (m) => {
        if (m.type === 'lease.request') {
          requestId = m.id;
        }
      },
    });
    const macRun = mac.run().catch(() => undefined);
    await session.connect();
    expect(session.state).toBe('ready');

    jest.useFakeTimers();
    try {
      const reqP = session.request('lease.request', { paneId: 'p1', cols: 80, rows: 24 });
      const assertion = expect(reqP).rejects.toBeInstanceOf(RequestTimeoutError);
      await jest.advanceTimersByTimeAsync(5_000);
      await assertion;
      expect(requestId).toBeDefined();

      // The Mac finally answers the expired request: the late reply must be
      // dropped, not routed to onMessage as if it were unsolicited.
      mac.sendSealed('lease.grant', { leaseId: 'L1' }, requestId);
      await jest.advanceTimersByTimeAsync(1);
      expect(inbox).toHaveLength(0);

      // The session itself survives: a fresh request still correlates.
      const pingP = session.request('session.ping', { ts: 1 });
      await jest.advanceTimersByTimeAsync(1);
      await expect(pingP).resolves.toMatchObject({ type: 'session.pong' });
    } finally {
      jest.useRealTimers();
    }

    session.close();
    await macRun;
  });

  it('tears the session down on a fatal session.error after ready', async () => {
    const { session, mac } = wire();
    const macRun = mac.run().catch(() => undefined);
    await session.connect();
    expect(session.state).toBe('ready');

    // A request in flight must reject with the remote error, not hang.
    const reqP = session.request('lease.request', { paneId: 'p1' });
    const assertion = expect(reqP).rejects.toBeInstanceOf(RemoteSessionError);

    mac.sendSealed('session.error', { code: 'internal', message: 'boom', fatal: true });
    await flush();

    await assertion;
    expect(session.state).toBe('closed');
    await macRun;
  });

  it('routes a non-fatal session.error after ready without closing', async () => {
    const { session, mac, inbox } = wire();
    const macRun = mac.run().catch(() => undefined);
    await session.connect();

    mac.sendSealed('session.error', { code: 'degraded', message: 'slow peer', fatal: false });
    await flush();

    expect(session.state).toBe('ready');
    expect(inbox.some((m) => m.type === 'session.error')).toBe(true);

    session.close();
    await macRun;
  });

  it('tears the session down when the transport fails to send', async () => {
    const identity = makePhoneIdentity(sodium);
    const macSeed = sodium.randomBytes(32);
    const [phoneT, macT] = makePipe();
    const mac = new FakeMac({
      transport: macT,
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
    });
    let failSends = false;
    const transport: TransportLike = {
      send: (frame) => (failSends ? Promise.reject(new Error('send boom')) : phoneT.send(frame)),
      receive: () => phoneT.receive(),
      close: () => phoneT.close(),
    };
    const session = new PhoneSession({
      transport,
      identity,
      mac: mac.pairedRecord({ relayUrl: 'wss://r/ws' }),
      sodium,
      deviceName: 'iPhone',
      appVersion: '1.0.0',
    });
    const macRun = mac.run().catch(() => undefined);
    await session.connect();
    expect(session.state).toBe('ready');

    // The transport dies on send: the pending request must reject with the send
    // error and the session must close like a receive-side transport failure.
    failSends = true;
    const reqP = session.request('pane.scrollback', { paneId: 'p1' });
    const assertion = expect(reqP).rejects.toThrow('send boom');
    await flush();

    await assertion;
    expect(session.state).toBe('closed');
    await macRun;
  });
});

describe('PhoneSession lanHint refresh', () => {
  it('surfaces a lanHint restated in session.ready', async () => {
    const sodium = await loadSodium();
    const identity = makePhoneIdentity(sodium);
    const macSeed = sodium.randomBytes(32);
    const [phoneT, macT] = makePipe();
    const mac = new FakeMac({
      transport: macT,
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
      lanHint: { host: 'renamed-mac.local', port: 7777 },
    });
    void mac.run().catch(() => undefined);

    const seen: Array<{ host: string; port: number }> = [];
    const session = new PhoneSession({
      transport: phoneT,
      identity,
      mac: mac.pairedRecord(),
      sodium,
      deviceName: 'phone',
      appVersion: '1.0',
      onLanHint: (hint) => seen.push(hint),
    });
    await session.connect();
    session.close();

    expect(seen).toEqual([{ host: 'renamed-mac.local', port: 7777 }]);
  });

  it('does not fire when the mac has no listener bound', async () => {
    const sodium = await loadSodium();
    const identity = makePhoneIdentity(sodium);
    const macSeed = sodium.randomBytes(32);
    const [phoneT, macT] = makePipe();
    const mac = new FakeMac({
      transport: macT,
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
    });
    void mac.run().catch(() => undefined);

    const seen: Array<{ host: string; port: number }> = [];
    const session = new PhoneSession({
      transport: phoneT,
      identity,
      mac: mac.pairedRecord(),
      sodium,
      deviceName: 'phone',
      appVersion: '1.0',
      onLanHint: (hint) => seen.push(hint),
    });
    await session.connect();
    session.close();

    // An absent hint means "no listener right now", never "forget the cached one".
    expect(seen).toEqual([]);
  });
});
