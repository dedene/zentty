/**
 * Runtime persistence adapter: backs the core {@link CompanionStorage} with
 * `expo-secure-store` (Keychain / Keystore). Memoized so identity and pairings
 * are read/written through one instance app-wide.
 */
import * as SecureStore from 'expo-secure-store';

import { CompanionStorage, secureStoreKV } from '@/core';

import { getSodium } from './sodium';

let cached: CompanionStorage | undefined;
let loading: Promise<CompanionStorage> | undefined;

export function getStorage(): Promise<CompanionStorage> {
  if (cached) {
    return Promise.resolve(cached);
  }
  if (!loading) {
    loading = getSodium().then((sodium) => {
      cached = new CompanionStorage(secureStoreKV(SecureStore), sodium);
      return cached;
    });
  }
  return loading;
}
