import { describe, expect, it } from '@jest/globals';

import { PushRegister } from '@zentty/wire';

import { PushRegistrar, type PushToken, type RegistrarSession } from '../pushRegistration';

interface Sent {
  type: string;
  payload: unknown;
}

function fakeSession(): RegistrarSession & { sent: Sent[] } {
  const sent: Sent[] = [];
  return {
    sent,
    send(type, payload) {
      sent.push({ type, payload });
    },
  };
}

const token: PushToken = { platform: 'apns', token: 'apns-device-token-abc' };

describe('PushRegistrar', () => {
  it('sends push.register with the right platform, token, and phone deviceId', () => {
    const session = fakeSession();
    const registrar = new PushRegistrar('phone-device-id', () => 1_700_000_000_000);

    const state = registrar.register(session, token);

    expect(session.sent).toHaveLength(1);
    expect(session.sent[0].type).toBe('push.register');
    // The payload must satisfy the wire schema exactly.
    const parsed = PushRegister.parse(session.sent[0].payload);
    expect(parsed).toEqual({
      platform: 'apns',
      token: 'apns-device-token-abc',
      deviceId: 'phone-device-id',
    });
    expect(state).toEqual({
      platform: 'apns',
      token: 'apns-device-token-abc',
      registeredAt: 1_700_000_000_000,
    });
    expect(registrar.state).toEqual(state);
  });

  it('is a clean no-op when no token is available (push unavailable)', () => {
    const session = fakeSession();
    const registrar = new PushRegistrar('phone-device-id');

    expect(registrar.register(session, undefined)).toBeUndefined();
    expect(session.sent).toHaveLength(0);
  });

  it('registerIfChanged only re-sends when the token actually changes', () => {
    const session = fakeSession();
    const registrar = new PushRegistrar('phone-device-id');

    registrar.register(session, token);
    expect(session.sent).toHaveLength(1);

    // Same token: skipped.
    expect(registrar.registerIfChanged(session, token)).toBeUndefined();
    expect(session.sent).toHaveLength(1);

    // Rotated token: re-sent.
    const rotated: PushToken = { platform: 'apns', token: 'apns-device-token-xyz' };
    const state = registrar.registerIfChanged(session, rotated);
    expect(state?.token).toBe('apns-device-token-xyz');
    expect(session.sent).toHaveLength(2);
    expect(PushRegister.parse(session.sent[1].payload).token).toBe('apns-device-token-xyz');

    // Platform change also counts as a change (apns -> fcm).
    expect(registrar.registerIfChanged(session, { platform: 'fcm', token: 'apns-device-token-xyz' })).toBeDefined();
    expect(session.sent).toHaveLength(3);
  });

  it('the session-ready path re-registers unconditionally after a reconnect', () => {
    const session = fakeSession();
    const registrar = new PushRegistrar('phone-device-id');

    registrar.register(session, token); // first session
    registrar.register(session, token); // fresh session: Mac lost its binding
    expect(session.sent).toHaveLength(2);
  });
});
