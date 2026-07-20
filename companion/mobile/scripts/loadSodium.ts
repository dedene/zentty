// Loads `libsodium-wrappers` and wraps it as the core's SodiumLike. This is the
// TEST/vector-generation adapter (Node). The runtime app supplies a
// react-native-libsodium adapter with the same SodiumLike shape.
import _sodium from 'libsodium-wrappers';

import { createSodium } from '../src/core/sodium';
import type { RawLibsodium, SodiumLike } from '../src/core/sodium';

let cached: SodiumLike | undefined;

export async function loadSodium(): Promise<SodiumLike> {
  if (cached) {
    return cached;
  }
  await _sodium.ready;
  cached = createSodium(_sodium as unknown as RawLibsodium);
  return cached;
}
