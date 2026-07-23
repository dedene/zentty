import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { Stack } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { usePushNotifications } from '@/lib/usePushNotifications';
import { useCompanionStore } from '@/store';
import { colors } from '@/theme';

SplashScreen.preventAutoHideAsync();

/**
 * TanStack Query is provided app-wide for request/response data (e.g. a future
 * transcript backfill). Live socket state deliberately does not use it — that
 * flows through the zustand store, fed by long-lived connection controllers.
 */
const queryClient = new QueryClient();

export default function RootLayout() {
  const hydrate = useCompanionStore((s) => s.hydrate);
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    hydrate()
      .catch(() => undefined)
      .finally(() => setHydrated(true));
  }, [hydrate]);

  // Enable push + deep-linking once the identity/pairings are loaded.
  usePushNotifications(hydrated);

  useEffect(() => {
    if (hydrated) {
      void SplashScreen.hideAsync();
    }
  }, [hydrated]);

  if (!hydrated) {
    return null;
  }

  return (
    <GestureHandlerRootView style={{ flex: 1, backgroundColor: colors.bg }}>
      <SafeAreaProvider>
        <QueryClientProvider client={queryClient}>
          <StatusBar style="light" />
          <Stack screenOptions={{ contentStyle: { backgroundColor: colors.bg } }}>
            <Stack.Screen name="(main)" options={{ headerShown: false }} />
            <Stack.Screen name="(pairing)" options={{ headerShown: false }} />
          </Stack>
        </QueryClientProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
