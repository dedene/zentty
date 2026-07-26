/** @jest-environment node */
import { beforeAll, beforeEach, describe, expect, it, jest } from '@jest/globals';

import {
  PairingTimeoutError,
  utf8Bytes,
  type PairingOfferData,
  type PhoneDeviceIdentity,
  type SodiumLike,
  type TransportLike,
} from '@/core';

import { loadSodium } from '../../../scripts/loadSodium';
import { makePhoneIdentity, makePipe } from '../../core/__tests__/harness';

// Assigned in beforeAll; the jest.mock factories below only dereference them
// inside closures, so they see the initialized values at call time.
let mockSodium: SodiumLike;
let mockIdentity: PhoneDeviceIdentity;

const mockOpeners = {
  openDirect: (() => Promise.reject(new Error('no direct'))) as (h: {
    host: string;
    port: number;
  }) => Promise<TransportLike>,
  openRelay: (() => Promise.reject(new Error('no relay'))) as (u: string) => Promise<TransportLike>,
};

jest.mock('@/runtime/transports', () => ({
  makeTransportOpeners: () => ({
    openDirect: (h: { host: string; port: number }) => mockOpeners.openDirect(h),
    openRelay: (u: string) => mockOpeners.openRelay(u),
  }),
}));
jest.mock('@/runtime/device', () => ({ phoneName: () => 'iPhone' }));
jest.mock('@/runtime/sodium', () => ({ getSodium: () => Promise.resolve(mockSodium) }));
jest.mock('@/runtime/storage', () => ({
  getStorage: () =>
    Promise.resolve({ loadOrCreateIdentity: () => Promise.resolve(mockIdentity) }),
}));

// Imported after the mocks are registered.
// eslint-disable-next-line import/first
import { PairingNoEndpointError, pairWithOffer } from '../pairing';

const decoder = new TextDecoder();

describe('pairWithOffer', () => {
  beforeAll(async () => {
    mockSodium = await loadSodium();
    mockIdentity = makePhoneIdentity(mockSodium);
  });

  beforeEach(() => {
    mockOpeners.openDirect = () => Promise.reject(new Error('no direct'));
    mockOpeners.openRelay = () => Promise.reject(new Error('no relay'));
  });

  function makeOffer(): PairingOfferData {
    return {
      relayUrl: 'wss://relay.example/ws',
      macDeviceId: 'mac-device-id',
      macPubKey: 'mac-pub-key',
      secret: 'c2VjcmV0',
      expiresAt: 9_999_999_999_999,
    };
  }

  it('resolves the paired Mac on confirm and closes the transport', async () => {
    const [phoneT, macT] = makePipe();
    mockOpeners.openRelay = () => Promise.resolve(phoneT);

    const macSide = (async () => {
      const frame = await macT.receive();
      const env = JSON.parse(decoder.decode(frame as Uint8Array)) as { type: string };
      expect(env.type).toBe('pairing.request');
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
      // pairWithOffer closes the transport once the exchange completes.
      expect(await macT.receive()).toBeNull();
    })();

    const paired = await pairWithOffer(makeOffer());
    await macSide;
    expect(paired.macName).toBe('Studio');
    expect(paired.macDeviceId).toBe('mac-device-id');
  });

  it('proceeds to connect when the offer has only a lanHint', async () => {
    const [phoneT, macT] = makePipe();
    mockOpeners.openDirect = () => Promise.resolve(phoneT);

    const macSide = (async () => {
      const frame = await macT.receive();
      const env = JSON.parse(decoder.decode(frame as Uint8Array)) as { type: string };
      expect(env.type).toBe('pairing.request');
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
      await macT.receive();
    })();

    const offer = { ...makeOffer(), relayUrl: '', lanHint: { host: '10.0.0.2', port: 4242 } };
    const paired = await pairWithOffer(offer);
    await macSide;
    expect(paired.macName).toBe('Studio');
  });

  it('proceeds to connect when the offer has only a relayUrl', async () => {
    const [phoneT, macT] = makePipe();
    mockOpeners.openRelay = () => Promise.resolve(phoneT);

    const macSide = (async () => {
      const frame = await macT.receive();
      const env = JSON.parse(decoder.decode(frame as Uint8Array)) as { type: string };
      expect(env.type).toBe('pairing.request');
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
      await macT.receive();
    })();

    const offer = makeOffer(); // relayUrl set, no lanHint
    const paired = await pairWithOffer(offer);
    await macSide;
    expect(paired.macName).toBe('Studio');
  });

  it('rejects with PairingNoEndpointError before attempting a connection when the offer has no lanHint and an empty relayUrl', async () => {
    const openDirect = jest.fn(() => Promise.reject(new Error('no direct')));
    const openRelay = jest.fn(() => Promise.reject(new Error('no relay')));
    mockOpeners.openDirect = openDirect as typeof mockOpeners.openDirect;
    mockOpeners.openRelay = openRelay as typeof mockOpeners.openRelay;

    const offer = { ...makeOffer(), relayUrl: '' };

    await expect(pairWithOffer(offer)).rejects.toBeInstanceOf(PairingNoEndpointError);
    expect(openDirect).not.toHaveBeenCalled();
    expect(openRelay).not.toHaveBeenCalled();
  });

  it('rejects with PairingTimeoutError when the whole flow stalls', async () => {
    jest.useFakeTimers();
    try {
      // The relay socket opens but the auth exchange never answers — nothing
      // below pairWithOffer bounds this, so the overall deadline must trip.
      mockOpeners.openRelay = () => new Promise<TransportLike>(() => undefined);

      const p = pairWithOffer(makeOffer(), Date.now(), 30_000);
      const assertion = expect(p).rejects.toBeInstanceOf(PairingTimeoutError);

      await jest.advanceTimersByTimeAsync(30_000);
      await assertion;
    } finally {
      jest.useRealTimers();
    }
  });
});
