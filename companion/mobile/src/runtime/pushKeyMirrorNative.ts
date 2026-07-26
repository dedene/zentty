/**
 * Native seam for the App Group key-material mirror: isolates the
 * `requireNativeModule` lookup of the local Expo module in
 * `modules/push-key-mirror` so pushKeyMirror.ts (and its tests) never touch
 * the native module registry directly.
 */
import { requireNativeModule } from 'expo';

/** The native surface of `modules/push-key-mirror`. */
export interface PushKeyMirrorNative {
  setKeyMaterial(json: string | null): void;
}

/**
 * The native module, or `null` when it is not linked into this binary — old
 * binaries, non-iOS platforms (the module is iOS-only, like the NSE itself),
 * and tests all land here.
 */
export function loadPushKeyMirrorNative(): PushKeyMirrorNative | null {
  try {
    return requireNativeModule<PushKeyMirrorNative>('PushKeyMirror');
  } catch {
    return null;
  }
}
