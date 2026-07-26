/**
 * Device metadata surfaced on the wire: the phone name the Mac shows in its
 * device list, and this build's app version for the session handshake.
 */
import Constants from 'expo-constants';
import * as Device from 'expo-device';

/** Human-readable phone name sent in `pairing.request` / `session.hello`. */
export function phoneName(): string {
  return Device.deviceName || Device.modelName || 'Zentty phone';
}

/** This build's marketing version (app.json `version`). */
export const APP_VERSION: string = Constants.expoConfig?.version ?? '1.0.0';
