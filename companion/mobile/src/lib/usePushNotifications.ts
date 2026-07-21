/**
 * Wires the app's push lifecycle: request permission + register the token once the
 * store is hydrated, present foreground wakes, and deep-link taps to the pane.
 *
 * Everything degrades cleanly. When push is unavailable the enable step is a
 * no-op, the listeners simply never fire, and the app keeps working on live
 * foreground updates alone.
 */
import { router } from 'expo-router';
import { useEffect } from 'react';

import type { PushDeepLink } from '@/core';
import {
  addResponseListener,
  configureForegroundHandler,
  getInitialNotificationData,
} from '@/runtime/notifications';
import { useCompanionStore } from '@/store';

// Present foreground notifications from the moment the module loads.
configureForegroundHandler();

/** Navigate to the pane a resolved wake points at. */
function openDeepLink(link: PushDeepLink): void {
  router.push({
    pathname: '/pane/[paneId]',
    params: { paneId: link.paneId, deviceId: link.macDeviceId },
  });
}

/**
 * Call once from the root layout after hydration. Enables push, routes taps, and
 * honours a notification that cold-started the app.
 */
export function usePushNotifications(enabled: boolean): void {
  const enablePush = useCompanionStore((s) => s.enablePush);
  const resolveNotification = useCompanionStore((s) => s.resolveNotification);

  useEffect(() => {
    if (!enabled) {
      return;
    }
    let cancelled = false;

    void enablePush();

    // A tap that launched the app from a cold start.
    void getInitialNotificationData().then(async (data) => {
      if (cancelled || !data) {
        return;
      }
      const link = await resolveNotification(data);
      if (!cancelled && link) {
        openDeepLink(link);
      }
    });

    // Taps while the app is running/backgrounded.
    const unsubscribe = addResponseListener((data) => {
      void resolveNotification(data).then((link) => {
        if (!cancelled && link) {
          openDeepLink(link);
        }
      });
    });

    return () => {
      cancelled = true;
      unsubscribe();
    };
  }, [enabled, enablePush, resolveNotification]);
}
