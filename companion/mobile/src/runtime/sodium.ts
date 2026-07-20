/**
 * Runtime native-crypto adapter: wraps `react-native-libsodium` as the core's
 * {@link SodiumLike}. Mirrors scripts/loadSodium.ts (the Node/test adapter) so the
 * app and the vector suite drive the exact same core code paths.
 */
import * as libsodium from 'react-native-libsodium';

import { createSodium, type RawLibsodium, type SodiumLike } from '@/core';

let cached: SodiumLike | undefined;
let loading: Promise<SodiumLike> | undefined;

/** Await libsodium's WASM/native init once, then return a memoized adapter. */
export function getSodium(): Promise<SodiumLike> {
  if (cached) {
    return Promise.resolve(cached);
  }
  if (!loading) {
    loading = libsodium.ready.then(() => {
      cached = createSodium(libsodium as unknown as RawLibsodium);
      return cached;
    });
  }
  return loading;
}
