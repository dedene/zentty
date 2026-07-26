/** @jest-environment node */
import { beforeEach, describe, expect, it, jest } from '@jest/globals';

import type { PairedMac, PhoneDeviceIdentity } from '@/core';

// Runtime seams mocked so the store runs without Expo/native modules. The store
// module (and its module-level `hydrating` promise + controller registry) is
// re-imported fresh per test via jest.resetModules().
const mockStorage = {
  loadOrCreateIdentity: jest.fn<() => Promise<PhoneDeviceIdentity>>(),
  listPairings: jest.fn<() => Promise<PairedMac[]>>(),
  addPairing: jest.fn<(mac: PairedMac) => Promise<void>>(),
  removePairing: jest.fn<(macDeviceId: string) => Promise<void>>(),
};

jest.mock('@/runtime/storage', () => ({
  getStorage: () => Promise.resolve(mockStorage),
}));
jest.mock('@/runtime/sodium', () => ({ getSodium: () => Promise.resolve({}) }));
jest.mock('@/runtime/device', () => ({ APP_VERSION: 'test', phoneName: () => 'iPhone' }));
jest.mock('@/runtime/notifications', () => ({
  fetchDevicePushToken: () => Promise.resolve(undefined),
}));

// MacConnection is replaced by a fake so no sockets/crypto spin up; every
// instance the store creates is recorded for inspection.
interface FakeConnection {
  start: jest.Mock<() => void>;
  refresh: jest.Mock<() => void>;
  wake: jest.Mock<() => void>;
  stop: jest.Mock<() => void>;
  registerPush: jest.Mock<() => void>;
}
const mockControllers: FakeConnection[] = [];

jest.mock('../macConnection', () => ({
  MacConnection: class {
    state = { status: 'connecting', sessionReady: false, worklanes: [], panes: {} };
    start = jest.fn();
    refresh = jest.fn();
    wake = jest.fn();
    stop = jest.fn();
    registerPush = jest.fn();
    paneController = jest.fn();
    constructor() {
      mockControllers.push(this as unknown as FakeConnection);
    }
  },
}));

const identity: PhoneDeviceIdentity = {
  seed: new Uint8Array(32),
  publicKey: new Uint8Array(32),
  deviceId: 'phone-1',
};

const pairedMac: PairedMac = {
  macDeviceId: 'mac-1',
  macPubKey: 'mac-1',
  macName: 'Studio Mac',
  pairedAt: 1,
};

function freshStore(): typeof import('../useCompanionStore') {
  jest.resetModules();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  return require('../useCompanionStore') as typeof import('../useCompanionStore');
}

describe('useCompanionStore hydration', () => {
  beforeEach(() => {
    mockControllers.length = 0;
    jest.clearAllMocks();
  });

  it('clears the cached promise on failure so a retry succeeds and surfaces pairings', async () => {
    const { useCompanionStore } = freshStore();

    mockStorage.loadOrCreateIdentity.mockRejectedValueOnce(new Error('keychain busy'));
    await expect(useCompanionStore.getState().hydrate()).rejects.toThrow('keychain busy');

    // Failed hydration leaves the store not-ready with no pairings...
    expect(useCompanionStore.getState().ready).toBe(false);
    expect(useCompanionStore.getState().macs).toEqual([]);

    // ...but the retry re-reads storage instead of re-throwing the cached
    // failure, so pairings appear once the transient error clears.
    mockStorage.loadOrCreateIdentity.mockResolvedValue(identity);
    mockStorage.listPairings.mockResolvedValue([pairedMac]);
    await useCompanionStore.getState().hydrate();

    const state = useCompanionStore.getState();
    expect(state.ready).toBe(true);
    expect(state.macs).toEqual([pairedMac]);
    expect(mockStorage.loadOrCreateIdentity).toHaveBeenCalledTimes(2);
  });

  it('connect resolves without throwing after a failed hydration, then connects once hydration recovers', async () => {
    const { useCompanionStore } = freshStore();

    mockStorage.loadOrCreateIdentity.mockRejectedValueOnce(new Error('keychain busy'));
    // `void connect(...)` call sites must not see an unhandled rejection.
    await expect(useCompanionStore.getState().connect('mac-1')).resolves.toBeUndefined();
    expect(mockControllers).toHaveLength(0);

    mockStorage.loadOrCreateIdentity.mockResolvedValue(identity);
    mockStorage.listPairings.mockResolvedValue([pairedMac]);
    await useCompanionStore.getState().connect('mac-1');

    expect(mockControllers).toHaveLength(1);
    expect(mockControllers[0].start).toHaveBeenCalledTimes(1);
  });
});

describe('useCompanionStore wakeConnections', () => {
  beforeEach(() => {
    mockControllers.length = 0;
    jest.clearAllMocks();
  });

  it('wakes every live controller, and is a harmless no-op with none', async () => {
    const { useCompanionStore } = freshStore();

    expect(() => useCompanionStore.getState().wakeConnections()).not.toThrow();

    mockStorage.loadOrCreateIdentity.mockResolvedValue(identity);
    mockStorage.listPairings.mockResolvedValue([
      pairedMac,
      { ...pairedMac, macDeviceId: 'mac-2', macPubKey: 'mac-2' },
    ]);
    await useCompanionStore.getState().connect('mac-1');
    await useCompanionStore.getState().connect('mac-2');
    expect(mockControllers).toHaveLength(2);

    useCompanionStore.getState().wakeConnections();
    expect(mockControllers[0].wake).toHaveBeenCalledTimes(1);
    expect(mockControllers[1].wake).toHaveBeenCalledTimes(1);
    // A foreground wake never force-drops a live session (that is refresh()).
    expect(mockControllers[0].refresh).not.toHaveBeenCalled();
    expect(mockControllers[1].refresh).not.toHaveBeenCalled();
  });
});
