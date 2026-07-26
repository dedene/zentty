/** @jest-environment node */
/**
 * Tests for the App Group key-material mirror (src/runtime/pushKeyMirror.ts).
 *
 * The native module (`modules/push-key-mirror`) is mocked at the
 * pushKeyMirrorNative seam — the same delegate pattern the store tests use for
 * `@/runtime/transports` — and storage is the real core {@link CompanionStorage}
 * over an in-memory KV store, so each test drives the exact states pairing and
 * unpairing leave behind and asserts what lands in the App Group.
 */
import { beforeEach, describe, expect, it, jest } from '@jest/globals';

import { CompanionStorage, encodeBase64Url, InMemoryKVStore, type PairedMac } from '@/core';
import { createStablelibSodium } from '@/runtime/sodium';

// Delegate so each test can reshape the native module (or make it missing).
const mockNative = {
  setKeyMaterial: jest.fn<(json: string | null) => void>(),
};
const mockLoadNative = jest.fn<() => typeof mockNative | null>(() => mockNative);

jest.mock('@/runtime/pushKeyMirrorNative', () => ({
  loadPushKeyMirrorNative: () => mockLoadNative(),
}));

const mockSodium = createStablelibSodium((length) => new Uint8Array(length));
const mockStorage = new CompanionStorage(new InMemoryKVStore(), mockSodium);

jest.mock('@/runtime/storage', () => ({
  getStorage: () => Promise.resolve(mockStorage),
}));

// Imported after the mocks are registered.
// eslint-disable-next-line import/first
import { syncPushKeyMirror } from '../pushKeyMirror';

function makeMac(byte: number): PairedMac {
  // 32 identical bytes so the base64url id is a plausible Ed25519 public key.
  const seed = new Uint8Array(32).fill(byte);
  const id = encodeBase64Url(mockSodium.signSeedKeypair(seed).publicKey);
  return { macDeviceId: id, macPubKey: id, macName: `Mac ${byte}`, pairedAt: 0 };
}

describe('syncPushKeyMirror', () => {
  beforeEach(async () => {
    mockNative.setKeyMaterial.mockClear();
    mockLoadNative.mockClear().mockReturnValue(mockNative);
    for (const mac of await mockStorage.listPairings()) {
      await mockStorage.removePairing(mac.macDeviceId);
    }
  });

  it('writes the full key-material blob once a Mac is paired', async () => {
    const mac = makeMac(1);
    await mockStorage.addPairing(mac);

    await syncPushKeyMirror();

    expect(mockNative.setKeyMaterial).toHaveBeenCalledTimes(1);
    const json = mockNative.setKeyMaterial.mock.calls[0][0];
    expect(typeof json).toBe('string');
    const material = JSON.parse(json as string) as {
      phoneX25519Priv: string;
      macX25519Pub: Record<string, string>;
    };
    // Exactly the keys NotificationService.swift's KeyMaterial.load parses.
    expect(Object.keys(material).sort()).toEqual(['macX25519Pub', 'phoneX25519Priv']);
    expect(material.phoneX25519Priv).toMatch(/^[A-Za-z0-9\-_]+$/);
    expect(Object.keys(material.macX25519Pub)).toEqual([mac.macDeviceId]);
  });

  it('clears the blob when the last Mac is unpaired', async () => {
    const mac = makeMac(2);
    await mockStorage.addPairing(mac);
    await mockStorage.removePairing(mac.macDeviceId);

    await syncPushKeyMirror();

    expect(mockNative.setKeyMaterial).toHaveBeenCalledTimes(1);
    expect(mockNative.setKeyMaterial).toHaveBeenCalledWith(null);
  });

  it('rewrites the blob without the unpaired Mac when others remain', async () => {
    const keep = makeMac(3);
    const drop = makeMac(4);
    await mockStorage.addPairing(keep);
    await mockStorage.addPairing(drop);
    await mockStorage.removePairing(drop.macDeviceId);

    await syncPushKeyMirror();

    const json = mockNative.setKeyMaterial.mock.calls[0][0] as string;
    const material = JSON.parse(json) as { macX25519Pub: Record<string, string> };
    expect(Object.keys(material.macX25519Pub)).toEqual([keep.macDeviceId]);
  });

  it('resolves without touching storage when the native module is not linked', async () => {
    // Old binaries and non-iOS platforms: the seam reports no module.
    mockLoadNative.mockReturnValue(null);

    await expect(syncPushKeyMirror()).resolves.toBeUndefined();
    expect(mockNative.setKeyMaterial).not.toHaveBeenCalled();
  });
});
