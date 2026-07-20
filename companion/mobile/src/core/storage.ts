/**
 * Persistence for the phone's device identity and its paired Macs, over an
 * injectable key/value store.
 *
 * Runtime backing is `expo-secure-store` (Keychain / Keystore); tests use the
 * in-memory store here. The core never imports `expo-secure-store` directly —
 * the app wires it in via {@link secureStoreKV} — so this module stays
 * UI/platform-free and unit-testable.
 */

import { decodeBase64Url, encodeBase64Url } from './base64url';
import type { SodiumLike } from './sodium';

/** Async key/value seam. Matches the shape both expo-secure-store and a Map expose. */
export interface KVStore {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

/** In-memory {@link KVStore} for tests. */
export class InMemoryKVStore implements KVStore {
  private readonly map = new Map<string, string>();

  async getItem(key: string): Promise<string | null> {
    return this.map.has(key) ? (this.map.get(key) as string) : null;
  }

  async setItem(key: string, value: string): Promise<void> {
    this.map.set(key, value);
  }

  async removeItem(key: string): Promise<void> {
    this.map.delete(key);
  }
}

/** The expo-secure-store async surface this adapter reaches into. */
export interface SecureStoreLike {
  getItemAsync(key: string): Promise<string | null>;
  setItemAsync(key: string, value: string): Promise<void>;
  deleteItemAsync(key: string): Promise<void>;
}

/** Adapt `expo-secure-store`'s async API to {@link KVStore}. */
export function secureStoreKV(secureStore: SecureStoreLike): KVStore {
  return {
    getItem: (key) => secureStore.getItemAsync(key),
    setItem: (key, value) => secureStore.setItemAsync(key, value),
    removeItem: (key) => secureStore.deleteItemAsync(key),
  };
}

/** This phone's stable Ed25519 identity, pinned by each Mac at pairing time. */
export interface PhoneDeviceIdentity {
  /** 32-byte Ed25519 seed (private). */
  seed: Uint8Array;
  /** 32-byte Ed25519 public key. */
  publicKey: Uint8Array;
  /** base64url of the public key — the phone's `deviceId` on the wire. */
  deviceId: string;
}

/** A Mac this phone has paired with. */
export interface PairedMac {
  /** base64url of the Mac's Ed25519 public key. */
  macDeviceId: string;
  /** base64url of the Mac's Ed25519 public key (equals `macDeviceId`; kept explicit). */
  macPubKey: string;
  /** Human-readable Mac name from `pairing.confirm`. */
  macName: string;
  /** Last-known LAN endpoint for the direct transport, if any. */
  lanHint?: { host: string; port: number };
  /** Relay URL to reach this Mac when off-LAN. */
  relayUrl?: string;
  /** ms-epoch of when the pairing completed. */
  pairedAt: number;
}

const IDENTITY_KEY = 'companion.identity.ed25519-seed';
const PAIRINGS_KEY = 'companion.paired-macs';
const ED25519_SEED_BYTES = 32;

/** Persists the device identity and paired-Mac list. */
export class CompanionStorage {
  private readonly kv: KVStore;
  private readonly sodium: SodiumLike;

  constructor(kv: KVStore, sodium: SodiumLike) {
    this.kv = kv;
    this.sodium = sodium;
  }

  /**
   * Loads the persisted identity, or mints and stores a fresh Ed25519 keypair on
   * first launch. The public key is always re-derived from the stored seed, so a
   * corrupt/short stored value is replaced rather than trusted.
   */
  async loadOrCreateIdentity(): Promise<PhoneDeviceIdentity> {
    const stored = await this.kv.getItem(IDENTITY_KEY);
    if (stored) {
      try {
        const seed = decodeBase64Url(stored);
        if (seed.length === ED25519_SEED_BYTES) {
          return this.identityFromSeed(seed);
        }
      } catch {
        // Fall through to regeneration on a malformed stored seed.
      }
    }
    const seed = this.sodium.randomBytes(ED25519_SEED_BYTES);
    await this.kv.setItem(IDENTITY_KEY, encodeBase64Url(seed));
    return this.identityFromSeed(seed);
  }

  private identityFromSeed(seed: Uint8Array): PhoneDeviceIdentity {
    const keypair = this.sodium.signSeedKeypair(seed);
    return {
      seed,
      publicKey: keypair.publicKey,
      deviceId: encodeBase64Url(keypair.publicKey),
    };
  }

  async listPairings(): Promise<PairedMac[]> {
    const stored = await this.kv.getItem(PAIRINGS_KEY);
    if (!stored) {
      return [];
    }
    try {
      const parsed: unknown = JSON.parse(stored);
      return Array.isArray(parsed) ? (parsed as PairedMac[]) : [];
    } catch {
      return [];
    }
  }

  async getPairing(macDeviceId: string): Promise<PairedMac | undefined> {
    const all = await this.listPairings();
    return all.find((p) => p.macDeviceId === macDeviceId);
  }

  /** Adds or replaces (by `macDeviceId`) a paired Mac, then persists. */
  async addPairing(mac: PairedMac): Promise<void> {
    const all = await this.listPairings();
    const index = all.findIndex((p) => p.macDeviceId === mac.macDeviceId);
    if (index >= 0) {
      all[index] = mac;
    } else {
      all.push(mac);
    }
    await this.kv.setItem(PAIRINGS_KEY, JSON.stringify(all));
  }

  /** Removes a paired Mac (unpair). No-op if unknown. */
  async removePairing(macDeviceId: string): Promise<void> {
    const all = await this.listPairings();
    const next = all.filter((p) => p.macDeviceId !== macDeviceId);
    if (next.length !== all.length) {
      await this.kv.setItem(PAIRINGS_KEY, JSON.stringify(next));
    }
  }
}
