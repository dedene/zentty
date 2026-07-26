/**
 * Runtime persistence adapter: backs the core {@link CompanionStorage} with
 * `expo-secure-store` (Keychain / Keystore) for identity + pairings, and plain
 * `AsyncStorage` for throwaway UI preferences. Memoized so everything is
 * read/written through one instance app-wide.
 */
import AsyncStorage from '@react-native-async-storage/async-storage';
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
      // AsyncStorage's getItem/setItem/removeItem already match the KVStore shape.
      cached = new CompanionStorage(secureStoreKV(SecureStore), sodium, AsyncStorage);
      return cached;
    });
  }
  return loading;
}
