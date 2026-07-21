/** @jest-environment node */
import { beforeAll, describe, expect, it, jest } from '@jest/globals';
import type { ParsedMessage } from '@zentty/wire';

import { loadSodium } from '../../../scripts/loadSodium';
import { encodeBase64Url } from '../base64url';
import { utf8Bytes } from '../crypto';
import {
  HandshakeError,
  PairingRejectedError,
  PhoneSession,
  VersionMismatchError,
  computePairingProof,
  runPairing,
} from '../session';
import type { PairingOfferData } from '../session';
import type { SodiumLike } from '../sodium';
import { FakeMac, makePhoneIdentity, makePipe } from './harness';

const flush = async (): Promise<void> => {
  for (let i = 0; i < 5; i += 1) {
    await new Promise((r) => setTimeout(r, 0));
  }
};

const decoder = new TextDecoder();

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
    afterReady?: (mac: FakeMac) => void;
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
    });
    const session = new PhoneSession({
      transport: phoneT,
      identity,
      mac: mac.pairedRecord({ relayUrl: 'wss://r/ws' }),
      sodium,
      deviceName: 'iPhone',
      appVersion: '1.0.0',
      handshakeTimeoutMs: options?.handshakeTimeoutMs,
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
});
