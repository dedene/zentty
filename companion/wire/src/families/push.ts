import { z } from 'zod';

// push.* — device-side of the push pipeline. The gateway REST /wake endpoint is
// not a device wire message and is intentionally not modeled here.

export const PushPlatform = z.enum(['apns', 'fcm']);
export type PushPlatform = z.infer<typeof PushPlatform>;

/** phone -> mac; mac forwards a signed registration to the gateway. */
export const PushRegister = z.object({
  platform: PushPlatform,
  token: z.string(),
  deviceId: z.string(),
});

/** phone -> mac. Requests a test notification. */
export const PushTest = z.object({});

export const pushMessages = {
  'push.register': PushRegister,
  'push.test': PushTest,
} as const;
