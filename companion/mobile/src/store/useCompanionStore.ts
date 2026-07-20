/**
 * The app's single zustand store: paired-Mac list, this phone's identity, and a
 * live {@link MacConnectionState} per Mac. Live socket data flows through here
 * (not TanStack Query) because it is push, not request/response — the store is fed
 * by long-lived {@link MacConnection} controllers held in a module registry.
 */
import { create } from 'zustand';

import type { PairedMac, PhoneDeviceIdentity } from '@/core';
import { APP_VERSION, phoneName } from '@/runtime/device';
import { getSodium } from '@/runtime/sodium';
import { getStorage } from '@/runtime/storage';

import { MacConnection, type MacConnectionState } from './macConnection';

/** Live controllers, keyed by macDeviceId. Kept out of React state on purpose. */
const controllers = new Map<string, MacConnection>();

export interface CompanionStore {
  ready: boolean;
  identity?: PhoneDeviceIdentity;
  macs: PairedMac[];
  views: Record<string, MacConnectionState>;

  /** Load identity + pairings from secure storage. Safe to call repeatedly. */
  hydrate: () => Promise<void>;
  /** Ensure a live connection to a Mac (idempotent) — call on screen focus. */
  connect: (macDeviceId: string) => Promise<void>;
  /** Force-reconnect a Mac (pull-to-refresh). */
  reconnect: (macDeviceId: string) => Promise<void>;
  /** Persist a freshly paired Mac and begin connecting. */
  addPairedMac: (mac: PairedMac) => Promise<void>;
  /** Remove a pairing locally and tear down its connection. */
  unpair: (macDeviceId: string) => Promise<void>;
}

let hydrating: Promise<void> | undefined;

export const useCompanionStore = create<CompanionStore>((set, get) => ({
  ready: false,
  identity: undefined,
  macs: [],
  views: {},

  hydrate: async () => {
    if (get().ready) {
      return;
    }
    if (!hydrating) {
      hydrating = (async () => {
        const storage = await getStorage();
        const identity = await storage.loadOrCreateIdentity();
        const macs = await storage.listPairings();
        set({ identity, macs, ready: true });
      })();
    }
    await hydrating;
  },

  connect: async (macDeviceId) => {
    await get().hydrate();
    const existing = controllers.get(macDeviceId);
    if (existing) {
      existing.start();
      return;
    }
    const { identity, macs } = get();
    const mac = macs.find((m) => m.macDeviceId === macDeviceId);
    if (!identity || !mac) {
      return;
    }
    const sodium = await getSodium();
    // Guard against a racing second connect() that resolved its await first.
    if (controllers.has(macDeviceId)) {
      controllers.get(macDeviceId)!.start();
      return;
    }
    const connection = new MacConnection({
      mac,
      identity,
      sodium,
      deviceName: phoneName(),
      appVersion: APP_VERSION,
      initialWorklanes: get().views[macDeviceId]?.worklanes,
      onChange: (state) =>
        set((s) => ({ views: { ...s.views, [macDeviceId]: state } })),
    });
    controllers.set(macDeviceId, connection);
    set((s) => ({ views: { ...s.views, [macDeviceId]: connection.state } }));
    connection.start();
  },

  reconnect: async (macDeviceId) => {
    const existing = controllers.get(macDeviceId);
    if (existing) {
      existing.refresh();
      return;
    }
    await get().connect(macDeviceId);
  },

  addPairedMac: async (mac) => {
    const storage = await getStorage();
    await storage.addPairing(mac);
    set((s) => {
      const macs = s.macs.some((m) => m.macDeviceId === mac.macDeviceId)
        ? s.macs.map((m) => (m.macDeviceId === mac.macDeviceId ? mac : m))
        : [...s.macs, mac];
      return { macs };
    });
    await get().connect(mac.macDeviceId);
  },

  unpair: async (macDeviceId) => {
    controllers.get(macDeviceId)?.stop();
    controllers.delete(macDeviceId);
    const storage = await getStorage();
    await storage.removePairing(macDeviceId);
    set((s) => {
      const views = { ...s.views };
      delete views[macDeviceId];
      return {
        macs: s.macs.filter((m) => m.macDeviceId !== macDeviceId),
        views,
      };
    });
  },
}));
