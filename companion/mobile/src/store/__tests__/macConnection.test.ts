/** @jest-environment node */
import { beforeAll, describe, expect, it, jest } from '@jest/globals';

import type { TransportLike } from '@/core';

import { loadSodium } from '../../../scripts/loadSodium';
import { FakeMac, makePhoneIdentity, makePipe } from '../../core/__tests__/harness';
import type { PhoneDeviceIdentity } from '../../core/storage';
import type { SodiumLike } from '../../core/sodium';

// Drive MacConnection with controllable transports: each openDirect() call pulls
// the next phone-side transport the test hands it, backed by a real FakeMac. This
// exercises the full crypto handshake so a session genuinely reaches `ready`.
const mockOpeners = {
  openDirect: (() => new Promise<TransportLike>(() => undefined)) as (
    h: { host: string; port: number },
  ) => Promise<TransportLike>,
  openRelay: (() => Promise.reject(new Error('no relay'))) as (u: string) => Promise<TransportLike>,
};

jest.mock('@/runtime/transports', () => ({
  makeTransportOpeners: () => ({
    openDirect: (h: { host: string; port: number }) => mockOpeners.openDirect(h),
    openRelay: (u: string) => mockOpeners.openRelay(u),
  }),
}));

// Imported after the mock is registered.
// eslint-disable-next-line import/first
import { MacConnection } from '../macConnection';

const flush = async (): Promise<void> => {
  for (let i = 0; i < 40; i += 1) {
    await new Promise((r) => setTimeout(r, 0));
  }
};

describe('MacConnection reconnect backoff', () => {
  let sodium: SodiumLike;
  let identity: PhoneDeviceIdentity;
  let macSeed: Uint8Array;

  beforeAll(async () => {
    sodium = await loadSodium();
  });

  /** A fresh transport pipe + running FakeMac for one connect cycle. */
  function newCycle(): { phoneT: TransportLike; macT: TransportLike; run: Promise<void> } {
    const [phoneT, macT] = makePipe();
    const mac = new FakeMac({
      transport: macT,
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
    });
    return { phoneT, macT, run: mac.run().catch(() => undefined) };
  }

  function makeHarness(overrides: {
    delays: number[];
    clock: { value: number };
    sessionUpThresholdMs: number;
    delay?: (ms: number) => Promise<void>;
  }) {
    identity = makePhoneIdentity(sodium);
    macSeed = sodium.randomBytes(32);
    const paired = new FakeMac({
      transport: makePipe()[0],
      sodium,
      macIdentitySeed: macSeed,
      phoneIdentityPublicKey: identity.publicKey,
    }).pairedRecord();

    let resolveNext: ((t: TransportLike) => void) | null = null;
    const ready: TransportLike[] = [];
    const provide = (t: TransportLike): void => {
      if (resolveNext) {
        const r = resolveNext;
        resolveNext = null;
        r(t);
      } else {
        ready.push(t);
      }
    };
    mockOpeners.openDirect = () =>
      new Promise<TransportLike>((resolve) => {
        const t = ready.shift();
        if (t) {
          resolve(t);
        } else {
          resolveNext = resolve;
        }
      });

    const conn = new MacConnection({
      mac: { ...paired, lanHint: { host: '10.0.0.1', port: 7777 } },
      identity,
      sodium,
      deviceName: 'iPhone',
      appVersion: '1.0.0',
      now: () => overrides.clock.value,
      delay:
        overrides.delay ??
        (async (ms: number) => {
          overrides.delays.push(ms);
        }),
      // Deterministic backoff (no jitter) so delays are exactly base * 2^n.
      reconnectBackoff: { base: 100, cap: 100_000, jitter: (c) => c },
      sessionUpThresholdMs: overrides.sessionUpThresholdMs,
      onChange: () => undefined,
    });
    return { conn, provide };
  }

  it('backs off exponentially when a Mac handshakes then instantly drops', async () => {
    const delays: number[] = [];
    const clock = { value: 1_000 };
    const { conn, provide } = makeHarness({ delays, clock, sessionUpThresholdMs: 30_000 });

    conn.start();
    // Three connect -> ready -> instant-drop cycles. The clock never advances, so
    // every session's uptime is 0 and the backoff must keep growing.
    for (let i = 0; i < 3; i += 1) {
      const cycle = newCycle();
      provide(cycle.phoneT);
      await flush(); // handshake completes; session reaches ready
      cycle.macT.close(); // Mac drops immediately
      await flush(); // run loop emits offline + schedules the backoff delay
    }

    expect(delays).toEqual([100, 200, 400]);

    // Unblock the loop so it can observe `stopped` and exit cleanly.
    conn.stop();
    provide(newCycle().phoneT);
    await flush();
  });

  it('resets the backoff after a session that stays up past the threshold', async () => {
    const delays: number[] = [];
    const clock = { value: 1_000 };
    const { conn, provide } = makeHarness({ delays, clock, sessionUpThresholdMs: 30_000 });

    conn.start();

    // Cycle 1: instant drop -> first backoff step.
    const c1 = newCycle();
    provide(c1.phoneT);
    await flush();
    c1.macT.close();
    await flush();

    // Cycle 2: healthy — advance the clock past the threshold before dropping, so
    // uptime >= threshold and the backoff resets to its base for the next reconnect.
    const c2 = newCycle();
    provide(c2.phoneT);
    await flush();
    clock.value += 30_000;
    c2.macT.close();
    await flush();

    expect(delays).toEqual([100, 100]);

    conn.stop();
    provide(newCycle().phoneT);
    await flush();
  });

  it('cuts a pending reconnect sleep short when woken (app foregrounded)', async () => {
    const delays: number[] = [];
    const clock = { value: 1_000 };
    // A delay that never settles on its own: only wake() can end the sleep.
    const { conn, provide } = makeHarness({
      delays,
      clock,
      sessionUpThresholdMs: 30_000,
      delay: (ms) => {
        delays.push(ms);
        return new Promise<void>(() => undefined);
      },
    });

    conn.start();
    const c1 = newCycle();
    provide(c1.phoneT);
    await flush(); // handshake completes; session reaches ready
    c1.macT.close();
    await flush(); // run loop emits offline + parks in the backoff sleep
    expect(delays).toEqual([100]);
    expect(conn.state.status).toBe('offline');

    // Foreground wake: the reconnect happens now, without the sleep elapsing.
    conn.wake();
    const c2 = newCycle();
    provide(c2.phoneT);
    await flush();

    expect(conn.state.status).toBe('connected');
    expect(conn.state.sessionReady).toBe(true);
    expect(delays).toEqual([100]); // backoff was reset, not re-entered

    conn.stop();
    provide(newCycle().phoneT);
    await flush();
  });

  it('wake() is a no-op while a session is live', async () => {
    const delays: number[] = [];
    const clock = { value: 1_000 };
    const { conn, provide } = makeHarness({ delays, clock, sessionUpThresholdMs: 30_000 });

    conn.start();
    provide(newCycle().phoneT);
    await flush();
    expect(conn.state.sessionReady).toBe(true);

    conn.wake();
    await flush();

    // Still on the same live session: no drop, no reconnect scheduled.
    expect(conn.state.status).toBe('connected');
    expect(conn.state.sessionReady).toBe(true);
    expect(delays).toEqual([]);

    conn.stop();
    await flush();
  });

  it('wake() does not restart a stopped connection', async () => {
    const delays: number[] = [];
    const clock = { value: 1_000 };
    const { conn, provide } = makeHarness({ delays, clock, sessionUpThresholdMs: 30_000 });

    conn.start();
    provide(newCycle().phoneT);
    await flush();
    conn.stop();
    await flush();

    let opens = 0;
    const previous = mockOpeners.openDirect;
    mockOpeners.openDirect = (h) => {
      opens += 1;
      return previous(h);
    };

    conn.wake();
    await flush();
    expect(opens).toBe(0);
  });
});
