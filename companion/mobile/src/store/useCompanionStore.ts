/**
 * The app's single zustand store: paired-Mac list, this phone's identity, and a
 * live {@link MacConnectionState} per Mac. Live socket data flows through here
 * (not TanStack Query) because it is push, not request/response — the store is fed
 * by long-lived {@link MacConnection} controllers held in a module registry.
 */
import { create } from 'zustand';

import {
  resolvePushDeepLink,
  type PairedMac,
  type PhoneDeviceIdentity,
  type PushDeepLink,
  type PushToken,
} from '@/core';
import { APP_VERSION, phoneName } from '@/runtime/device';
import { fetchDevicePushToken } from '@/runtime/notifications';
import { getSodium } from '@/runtime/sodium';
import { getStorage } from '@/runtime/storage';

import { MacConnection, type MacConnectionState } from './macConnection';
import type { PaneController } from './paneController';

/** Live controllers, keyed by macDeviceId. Kept out of React state on purpose. */
const controllers = new Map<string, MacConnection>();

export interface CompanionStore {
  ready: boolean;
  identity?: PhoneDeviceIdentity;
  macs: PairedMac[];
  views: Record<string, MacConnectionState>;
  /** The phone's native push token, once permission is granted and it is fetched. */
  pushToken?: PushToken;

  /** Load identity + pairings from secure storage. Safe to call repeatedly. */
  hydrate: () => Promise<void>;
  /**
   * Request notification permission, fetch the native device token, and register
   * it with every connected Mac. Degrades cleanly to a no-op when push is
   * unavailable (simulator, denied, no entitlement) — the dashboard still updates
   * live in the foreground.
   */
  enablePush: () => Promise<void>;
  /**
   * Resolve a tapped/received wake notification's `data` payload to a deep-link
   * target by decrypting its sealed content offline. `undefined` when it is not a
   * recognizable wake for a paired Mac.
   */
  resolveNotification: (data: unknown) => Promise<PushDeepLink | undefined>;
  /** Ensure a live connection to a Mac (idempotent) — call on screen focus. */
  connect: (macDeviceId: string) => Promise<void>;
  /** Force-reconnect a Mac (pull-to-refresh). */
  reconnect: (macDeviceId: string) => Promise<void>;
  /** Persist a freshly paired Mac and begin connecting. */
  addPairedMac: (mac: PairedMac) => Promise<void>;
  /** Remove a pairing locally and tear down its connection. */
  unpair: (macDeviceId: string) => Promise<void>;
  /**
   * Ensure a live connection, then resolve the pane's runtime controller. The
   * pane detail screen calls this on focus and drives watch/input/lease/
   * transcript on the returned controller; its state streams into `views`.
   */
  ensurePaneController: (macDeviceId: string, paneId: string) => Promise<PaneController | undefined>;
}

let hydrating: Promise<void> | undefined;

export const useCompanionStore = create<CompanionStore>((set, get) => ({
  ready: false,
  identity: undefined,
  macs: [],
  views: {},
  pushToken: undefined,

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

  enablePush: async () => {
    const token = await fetchDevicePushToken();
    if (!token) {
      return;
    }
    if (get().pushToken?.token === token.token && get().pushToken?.platform === token.platform) {
      return;
    }
    set({ pushToken: token });
    // Push the new token to every live connection immediately.
    for (const connection of controllers.values()) {
      connection.registerPush();
    }
  },

  resolveNotification: async (data) => {
    await get().hydrate();
    const { identity, macs } = get();
    if (!identity) {
      return undefined;
    }
    const sodium = await getSodium();
    return resolvePushDeepLink(sodium, {
      data,
      phoneIdentitySeed: identity.seed,
      macPublicKeyFor: (macDeviceId) =>
        macs.find((m) => m.macDeviceId === macDeviceId)?.macPubKey,
    });
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
      pushToken: () => get().pushToken,
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

  ensurePaneController: async (macDeviceId, paneId) => {
    await get().connect(macDeviceId);
    return controllers.get(macDeviceId)?.paneController(paneId);
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
