/**
 * Runtime notifications adapter: the only module that imports expo-notifications.
 *
 * Everything here degrades cleanly. On a simulator, without an APNs/FCM
 * entitlement, or when the user denies permission, {@link fetchDevicePushToken}
 * resolves `undefined` and the app keeps working — the live dashboard still
 * updates whenever the app is foregrounded (the push pipeline only adds a wake
 * when the app is backgrounded). No live Apple/Google credentials are required for
 * any of this to load or for the app to run.
 */
import * as Notifications from 'expo-notifications';

import type { PushToken } from '@/core';

/** Foreground presentation: show the banner + list, no sound/badge by default. */
export function configureForegroundHandler(): void {
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldPlaySound: false,
      shouldSetBadge: false,
      shouldShowBanner: true,
      shouldShowList: true,
    }),
  });
}

/** Whether notification permission is granted, requesting it once if it can. */
export async function ensurePushPermission(): Promise<boolean> {
  const current = await Notifications.getPermissionsAsync();
  if (current.granted) {
    return true;
  }
  if (!current.canAskAgain) {
    return false;
  }
  const requested = await Notifications.requestPermissionsAsync({
    ios: { allowAlert: true, allowBadge: true, allowSound: true },
  });
  return requested.granted;
}

/**
 * Fetch the native device push token, mapping expo's platform tag to the wire
 * platform. Returns `undefined` when a token cannot be obtained (no entitlement,
 * simulator, offline APNs) — the caller treats that as "push unavailable" and
 * relies on foreground updates.
 */
export async function fetchDevicePushToken(): Promise<PushToken | undefined> {
  try {
    const granted = await ensurePushPermission();
    if (!granted) {
      return undefined;
    }
    const token = await Notifications.getDevicePushTokenAsync();
    const platform = token.type === 'ios' ? 'apns' : 'fcm';
    const data = typeof token.data === 'string' ? token.data : String(token.data);
    if (!data) {
      return undefined;
    }
    return { platform, token: data };
  } catch {
    return undefined;
  }
}

/** Subscribe to taps on a delivered notification. Returns an unsubscribe fn. */
export function addResponseListener(
  handler: (data: Record<string, unknown>) => void,
): () => void {
  const sub = Notifications.addNotificationResponseReceivedListener((response) => {
    const data = response.notification.request.content.data;
    if (data && typeof data === 'object') {
      handler(data as Record<string, unknown>);
    }
  });
  return () => sub.remove();
}

/** Subscribe to notifications received while the app is foregrounded. */
export function addReceivedListener(
  handler: (data: Record<string, unknown>) => void,
): () => void {
  const sub = Notifications.addNotificationReceivedListener((notification) => {
    const data = notification.request.content.data;
    if (data && typeof data === 'object') {
      handler(data as Record<string, unknown>);
    }
  });
  return () => sub.remove();
}

/**
 * The notification that launched the app from a cold start (tapped while the app
 * was not running), if any. Returns its data payload.
 */
export async function getInitialNotificationData(): Promise<Record<string, unknown> | undefined> {
  const response = await Notifications.getLastNotificationResponseAsync();
  const data = response?.notification.request.content.data;
  return data && typeof data === 'object' ? (data as Record<string, unknown>) : undefined;
}
