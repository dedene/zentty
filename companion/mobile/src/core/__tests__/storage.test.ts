/** @jest-environment node */
import { beforeAll, describe, expect, it } from '@jest/globals';

import { loadSodium } from '../../../scripts/loadSodium';
import { CompanionStorage, CorruptPairingsError, InMemoryKVStore } from '../storage';
import type { PairedMac } from '../storage';
import type { SodiumLike } from '../sodium';

describe('CompanionStorage', () => {
  let sodium: SodiumLike;
  beforeAll(async () => {
    sodium = await loadSodium();
  });

  it('mints and persists a stable identity', async () => {
    const kv = new InMemoryKVStore();
    const storage = new CompanionStorage(kv, sodium);

    const first = await storage.loadOrCreateIdentity();
    expect(first.deviceId).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(first.publicKey).toHaveLength(32);

    // A second load (fresh instance, same store) returns the same identity.
    const second = await new CompanionStorage(kv, sodium).loadOrCreateIdentity();
    expect(second.deviceId).toBe(first.deviceId);
    expect(Array.from(second.seed)).toEqual(Array.from(first.seed));
  });

  it('regenerates on a malformed stored seed', async () => {
    const kv = new InMemoryKVStore();
    await kv.setItem('companion.identity.ed25519-seed', 'not-a-valid-seed');
    const identity = await new CompanionStorage(kv, sodium).loadOrCreateIdentity();
    expect(identity.publicKey).toHaveLength(32);
    // The bad value was replaced with a real 32-byte seed.
    const stored = await kv.getItem('companion.identity.ed25519-seed');
    expect(stored).not.toBe('not-a-valid-seed');
  });

  it('adds, replaces, lists, and removes pairings', async () => {
    const storage = new CompanionStorage(new InMemoryKVStore(), sodium);
    const mac: PairedMac = {
      macDeviceId: 'mac-1',
      macPubKey: 'mac-1',
      macName: 'Studio',
      relayUrl: 'wss://r/ws',
      pairedAt: 100,
    };
    await storage.addPairing(mac);
    await storage.addPairing({ ...mac, macName: 'Studio (renamed)' }); // replace by id

    const all = await storage.listPairings();
    expect(all).toHaveLength(1);
    expect(all[0].macName).toBe('Studio (renamed)');
    expect(await storage.getPairing('mac-1')).toBeDefined();

    await storage.addPairing({ ...mac, macDeviceId: 'mac-2', macPubKey: 'mac-2' });
    expect(await storage.listPairings()).toHaveLength(2);

    await storage.removePairing('mac-1');
    const remaining = await storage.listPairings();
    expect(remaining).toHaveLength(1);
    expect(remaining[0].macDeviceId).toBe('mac-2');
  });

  it('returns an empty list when nothing is stored or the value is corrupt', async () => {
    const storage = new CompanionStorage(new InMemoryKVStore(), sodium);
    expect(await storage.listPairings()).toEqual([]);

    const kv = new InMemoryKVStore();
    await kv.setItem('companion.paired-macs', '{not json');
    expect(await new CompanionStorage(kv, sodium).listPairings()).toEqual([]);
  });

  it('refuses to overwrite a corrupt pairings blob on add (no silent data loss)', async () => {
    const kv = new InMemoryKVStore();
    const corrupt = '{not json — a transient bad read';
    await kv.setItem('companion.paired-macs', corrupt);
    const storage = new CompanionStorage(kv, sodium);
    const mac: PairedMac = {
      macDeviceId: 'mac-1',
      macPubKey: 'mac-1',
      macName: 'Studio',
      pairedAt: 1,
    };

    await expect(storage.addPairing(mac)).rejects.toBeInstanceOf(CorruptPairingsError);

    // The corrupt blob was NOT replaced by a wiped single-element array...
    expect(await kv.getItem('companion.paired-macs')).toBe(corrupt);
    // ...and a timestamped backup of it was retained for recovery.
    const backup = await kv.getItem(
      (await keysStartingWith(kv, 'companion.paired-macs.corrupt.'))[0] ?? '',
    );
    expect(backup).toBe(corrupt);
  });

  it('refuses to wipe pairings via remove when the stored blob is corrupt', async () => {
    const kv = new InMemoryKVStore();
    const corrupt = 'null'; // valid JSON, but not an array
    await kv.setItem('companion.paired-macs', corrupt);
    const storage = new CompanionStorage(kv, sodium);

    await expect(storage.removePairing('mac-1')).rejects.toBeInstanceOf(CorruptPairingsError);
    expect(await kv.getItem('companion.paired-macs')).toBe(corrupt);
  });
});

/** Peek at the in-memory store's keys (test-only) to find the backup entry. */
async function keysStartingWith(kv: InMemoryKVStore, prefix: string): Promise<string[]> {
  const map = (kv as unknown as { map: Map<string, string> }).map;
  return [...map.keys()].filter((k) => k.startsWith(prefix));
}
