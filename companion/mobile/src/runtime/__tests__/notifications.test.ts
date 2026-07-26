/** @jest-environment node */
/**
 * Tests for the push-token platform mapping in src/runtime/notifications.ts.
 *
 * expo-notifications is mocked at the module boundary; each test drives the
 * native token type expo would report and asserts the wire platform (or the
 * deliberate "push unavailable" fallback for an unsupported type).
 */
import { beforeEach, describe, expect, it, jest } from '@jest/globals';

const mockGetPermissions = jest.fn<() => Promise<{ granted: boolean; canAskAgain: boolean }>>();
const mockGetDevicePushToken = jest.fn<() => Promise<{ type: string; data: unknown }>>();

jest.mock('expo-notifications', () => ({
  getPermissionsAsync: () => mockGetPermissions(),
  requestPermissionsAsync: () => Promise.resolve({ granted: true }),
  getDevicePushTokenAsync: () => mockGetDevicePushToken(),
  setNotificationHandler: () => undefined,
  addNotificationResponseReceivedListener: () => ({ remove: () => undefined }),
  getLastNotificationResponseAsync: () => Promise.resolve(null),
}));

// Imported after the mocks are registered.
// eslint-disable-next-line import/first
import { fetchDevicePushToken } from '../notifications';

describe('fetchDevicePushToken', () => {
  beforeEach(() => {
    mockGetPermissions.mockClear().mockResolvedValue({ granted: true, canAskAgain: true });
    mockGetDevicePushToken.mockClear();
  });

  it('maps an iOS device token to apns', async () => {
    mockGetDevicePushToken.mockResolvedValue({ type: 'ios', data: 'apns-token' });

    await expect(fetchDevicePushToken()).resolves.toEqual({
      platform: 'apns',
      token: 'apns-token',
    });
  });

  it('maps an Android device token to fcm', async () => {
    mockGetDevicePushToken.mockResolvedValue({ type: 'android', data: 'fcm-token' });

    await expect(fetchDevicePushToken()).resolves.toEqual({
      platform: 'fcm',
      token: 'fcm-token',
    });
  });

  it('treats an unsupported token type as push unavailable', async () => {
    mockGetDevicePushToken.mockResolvedValue({ type: 'web', data: 'web-token' });

    await expect(fetchDevicePushToken()).resolves.toBeUndefined();
  });

  it('resolves undefined when permission is denied', async () => {
    mockGetPermissions.mockResolvedValue({ granted: false, canAskAgain: false });

    await expect(fetchDevicePushToken()).resolves.toBeUndefined();
    expect(mockGetDevicePushToken).not.toHaveBeenCalled();
  });
});
