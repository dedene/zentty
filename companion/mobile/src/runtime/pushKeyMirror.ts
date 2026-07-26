/**
 * Runtime bridge that mirrors the push-seal key material into the iOS App
 * Group so the Notification Service Extension can unseal wake banners while
 * the app is not running.
 *
 * The native side is the local Expo module in `modules/push-key-mirror`
 * (autolinked by expo-modules-autolinking at prebuild/pod-install), reached
 * through the seam in pushKeyMirrorNative.ts. Mirroring is full-replace:
 * every call rebuilds the blob from current storage (phone identity + paired
 * Macs) and rewrites it, or removes it when no Macs remain paired — so
 * callers never have to diff anything.
 *
 * Best-effort by design: a missing native module (old binary, non-iOS
 * platform, tests) or a storage hiccup must never break pairing/unpairing —
 * the NSE simply keeps showing the generic banner. Callers: after a successful
 * pair and after every unpair.
 */
import { buildPushKeyMaterial } from '@/core';

import { loadPushKeyMirrorNative } from './pushKeyMirrorNative';
import { getSodium } from './sodium';
import { getStorage } from './storage';

/**
 * Rebuild the NSE key material from storage and write it into the App Group.
 * Resolves without doing anything when the native module is unavailable; never
 * rejects — failures only mean the NSE falls back to generic banners.
 */
export async function syncPushKeyMirror(): Promise<void> {
  // No memoization: requireNativeModule is already cached natively, and a
  // fresh lookup keeps the seam trivially testable.
  const mirror = loadPushKeyMirrorNative();
  if (!mirror) {
    return;
  }
  try {
    const storage = await getStorage();
    const sodium = await getSodium();
    const macs = await storage.listPairings();
    if (macs.length === 0) {
      // Last Mac unpaired: clear the material so the NSE stops unsealing.
      mirror.setKeyMaterial(null);
      return;
    }
    const identity = await storage.loadOrCreateIdentity();
    const material = buildPushKeyMaterial(sodium, { phoneIdentitySeed: identity.seed, macs });
    mirror.setKeyMaterial(JSON.stringify(material));
  } catch {
    // Best-effort mirror: leave the previous App Group value untouched.
  }
}
