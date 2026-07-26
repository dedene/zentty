/**
 * Push-registration bookkeeping for one paired Mac.
 *
 * The phone obtains a native APNs/FCM device token (see runtime/notifications.ts)
 * and, over the encrypted session, hands it to each paired Mac with a
 * `push.register` frame. The Mac forwards a signed registration to the push
 * gateway, binding `(macDeviceId, phoneDeviceId, token)` so a later wake can reach
 * this phone. This module is the pure, UI-free half: it owns no sockets and no
 * native modules — it takes a minimal {@link RegistrarSession} and a token, emits
 * the wire frame, and records what it last registered so a screen can show status
 * and callers can avoid redundant sends.
 */

import type { PushPlatform } from '@zentty/wire';

/** A native push token plus the platform that minted it. */
export interface PushToken {
  platform: PushPlatform;
  /** The raw APNs (iOS) or FCM (Android) device token string. */
  token: string;
}

/** The minimal session surface the registrar needs — just a fire-and-forget send. */
export interface RegistrarSession {
  send(type: string, payload: unknown): void;
}

/** What the phone most recently registered with a Mac, for status display. */
export interface PushRegistrationState {
  platform: PushPlatform;
  token: string;
  /** ms-epoch when the `push.register` frame was sent. */
  registeredAt: number;
}

/**
 * Tracks push registration for a single Mac connection. One instance per
 * {@link MacConnection}; it outlives individual sessions so a token that has not
 * changed is not re-sent within the same connection, while every fresh session
 * (or a rotated token) does re-register — the Mac's registration is in-memory and
 * must be re-established after it restarts.
 */
export class PushRegistrar {
  private readonly phoneDeviceId: string;
  private readonly now: () => number;
  private last?: PushRegistrationState;

  constructor(phoneDeviceId: string, now: () => number = Date.now) {
    this.phoneDeviceId = phoneDeviceId;
    this.now = now;
  }

  /** The most recent successful registration, if any. */
  get state(): PushRegistrationState | undefined {
    return this.last;
  }

  /**
   * Register `token` with the Mac over `session`. A no-op (returns the current
   * state) when there is no token yet — the app degrades cleanly to foreground
   * updates when notifications are unavailable or denied. Always sends when a
   * token is present so a new session re-establishes the Mac's in-memory binding.
   */
  register(session: RegistrarSession, token: PushToken | undefined): PushRegistrationState | undefined {
    if (!token) {
      return this.last;
    }
    session.send('push.register', {
      platform: token.platform,
      token: token.token,
      deviceId: this.phoneDeviceId,
    });
    this.last = { platform: token.platform, token: token.token, registeredAt: this.now() };
    return this.last;
  }

  /**
   * Re-register only if `token` differs from what was last sent (token rotation
   * while already connected). Returns the state if a frame was sent, else
   * `undefined`.
   */
  registerIfChanged(
    session: RegistrarSession,
    token: PushToken | undefined,
  ): PushRegistrationState | undefined {
    if (!token) {
      return undefined;
    }
    if (this.last && this.last.token === token.token && this.last.platform === token.platform) {
      return undefined;
    }
    return this.register(session, token);
  }
}
