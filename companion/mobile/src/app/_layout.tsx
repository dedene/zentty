import { Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import * as SystemUI from 'expo-system-ui';
import { useEffect, useState } from 'react';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { subscribeForegroundRecovery } from '@/lib/foregroundRecovery';
import { navTheme } from '@/lib/navTheme';
import { usePushNotifications } from '@/lib/usePushNotifications';
import { syncPushKeyMirror } from '@/runtime/pushKeyMirror';
import { useCompanionStore } from '@/store';
import { colors } from '@/theme';

SplashScreen.preventAutoHideAsync();
// Paint the native window itself — the last surface that can peek through
// during transitions and modal presentations (defaults to system white).
void SystemUI.setBackgroundColorAsync(colors.bg);

/** Launch hydration retry pacing for a transient SecureStore failure. */
const HYDRATE_RETRY_DELAY_MS = 1_500;
const HYDRATE_MAX_ATTEMPTS = 4;

export default function RootLayout() {
  const hydrate = useCompanionStore((s) => s.hydrate);
  const [hydrated, setHydrated] = useState(false);

  // The retry timer lives inside the nested `attempt` closure; the cleanup
  // below clears it (`clearTimeout(timer)`) and sets `cancelled`.
  // react-doctor-disable-next-line react-doctor/effect-needs-cleanup
  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let attempts = 0;

    const attempt = (): void => {
      attempts += 1;
      hydrate()
        .then(() => {
          if (!cancelled) {
            setHydrated(true);
          }
          // Self-heal the NSE key material for installs that paired before the
          // mirror existed (best-effort; a no-op when unlinked).
          void syncPushKeyMirror();
        })
        .catch(() => {
          if (cancelled) {
            return;
          }
          if (attempts < HYDRATE_MAX_ATTEMPTS) {
            timer = setTimeout(attempt, HYDRATE_RETRY_DELAY_MS);
          } else {
            // Render degraded rather than wedge on the splash screen; the
            // foreground-recovery subscription below retries hydration, and
            // pairings appear once storage reads again.
            setHydrated(true);
          }
        });
    };
    attempt();

    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [hydrate]);

  // App-lifetime foreground recovery: retry a failed hydration and wake every
  // connection from a residual reconnect backoff.
  useEffect(() => subscribeForegroundRecovery(), []);

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
        <StatusBar style="light" />
        <ThemeProvider value={navTheme}>
          <Stack screenOptions={{ contentStyle: { backgroundColor: colors.bg } }}>
            <Stack.Screen name="(main)" options={{ headerShown: false }} />
            <Stack.Screen name="(pairing)" options={{ headerShown: false }} />
          </Stack>
        </ThemeProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
