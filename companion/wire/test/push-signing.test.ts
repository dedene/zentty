import { generateKeyPairSync, sign, verify } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  PUSH_REGISTER_SIGN_PREFIX,
  PUSH_WAKE_SIGN_PREFIX,
  PushRegisterRequest,
  PushWakeRequest,
  pushRegisterSigningString,
  pushWakeSigningString,
} from '../src/index';

// The push gateway signing strings are a cross-language contract: the Swift Mac
// signer, the Node gateway verifier, and these tests must all produce the exact
// same UTF-8 bytes. These assertions freeze the byte layout so a Swift change
// that drifts is caught by the shared expectations below.

describe('pushWakeSigningString', () => {
  it('is a prefix line + alphabetical key=value lines, no trailing newline', () => {
    const s = pushWakeSigningString({
      deviceId: 'PHONE_ID',
      platform: 'apns',
      sealedPayload: 'U0VBTEVE',
      token: 'DEVICE_TOKEN',
    });
    expect(s).toBe(
      [
        'zentty-push-wake:v1',
        'deviceId=PHONE_ID',
        'platform=apns',
        'sealedPayload=U0VBTEVE',
        'token=DEVICE_TOKEN',
      ].join('\n'),
    );
    expect(s.startsWith(PUSH_WAKE_SIGN_PREFIX + '\n')).toBe(true);
    expect(s.endsWith('\n')).toBe(false);
  });

  it('orders fields deterministically regardless of input key order', () => {
    const a = pushWakeSigningString({
      token: 't',
      sealedPayload: 's',
      platform: 'fcm',
      deviceId: 'd',
    });
    const b = pushWakeSigningString({
      deviceId: 'd',
      platform: 'fcm',
      sealedPayload: 's',
      token: 't',
    });
    expect(a).toBe(b);
  });
});

describe('pushRegisterSigningString', () => {
  it('is a prefix line + alphabetical key=value lines, no trailing newline', () => {
    const s = pushRegisterSigningString({
      macDeviceId: 'MAC_ID',
      phoneDeviceId: 'PHONE_ID',
      platform: 'fcm',
      token: 'DEVICE_TOKEN',
    });
    expect(s).toBe(
      [
        'zentty-push-register:v1',
        'macDeviceId=MAC_ID',
        'phoneDeviceId=PHONE_ID',
        'platform=fcm',
        'token=DEVICE_TOKEN',
      ].join('\n'),
    );
    expect(s.startsWith(PUSH_REGISTER_SIGN_PREFIX + '\n')).toBe(true);
  });

  it('has a distinct domain prefix from the wake string', () => {
    const fields = {
      macDeviceId: 'm',
      phoneDeviceId: 'p',
      platform: 'apns',
      token: 't',
    } as const;
    const register = pushRegisterSigningString(fields);
    const wake = pushWakeSigningString({
      deviceId: 'p',
      platform: 'apns',
      sealedPayload: 't',
      token: 't',
    });
    expect(register).not.toBe(wake);
    expect(PUSH_REGISTER_SIGN_PREFIX).not.toBe(PUSH_WAKE_SIGN_PREFIX);
  });
});

describe('Ed25519 sign/verify over the signing strings', () => {
  it('a mac key signs a wake string that verifies (and a tampered field does not)', () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const fields = {
      deviceId: 'phone-1',
      platform: 'apns',
      sealedPayload: 'U0VBTEVE',
      token: 'tok-1',
    } as const;
    const msg = Buffer.from(pushWakeSigningString(fields), 'utf8');
    const sig = sign(null, msg, privateKey);

    expect(verify(null, msg, publicKey, sig)).toBe(true);

    // A tampered payload must not verify against the original signature.
    const tampered = Buffer.from(
      pushWakeSigningString({ ...fields, sealedPayload: 'VEFNUEVSRUQ' }),
      'utf8',
    );
    expect(verify(null, tampered, publicKey, sig)).toBe(false);
  });

  it('a register string signs and verifies', () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const msg = Buffer.from(
      pushRegisterSigningString({
        macDeviceId: 'mac-1',
        phoneDeviceId: 'phone-1',
        platform: 'fcm',
        token: 'tok-1',
      }),
      'utf8',
    );
    const sig = sign(null, msg, privateKey);
    expect(verify(null, msg, publicKey, sig)).toBe(true);
  });
});

describe('gateway request schemas', () => {
  it('accept well-formed bodies and reject unknown platforms / missing sig', () => {
    expect(
      PushWakeRequest.safeParse({
        deviceId: 'p',
        token: 't',
        platform: 'apns',
        sealedPayload: 's',
        sig: 'x',
      }).success,
    ).toBe(true);
    expect(
      PushWakeRequest.safeParse({
        deviceId: 'p',
        token: 't',
        platform: 'webpush',
        sealedPayload: 's',
        sig: 'x',
      }).success,
    ).toBe(false);
    expect(
      PushRegisterRequest.safeParse({
        macDeviceId: 'm',
        phoneDeviceId: 'p',
        platform: 'fcm',
        token: 't',
      }).success,
    ).toBe(false);
  });
});
