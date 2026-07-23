import {
  createPublicKey,
  generateKeyPairSync,
  sign as nodeSign,
  verify as nodeVerify,
} from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { pushWakeSigningString } from '@zentty/wire';
import {
  decodeJwt,
  signJwtES256,
  signJwtRS256,
  verifyEd25519,
} from '../src/push/signing.js';

// These prove the credential math end to end against TEST keys generated here —
// never a real Apple/Google key. An EC P-256 key stands in for the APNs .p8; an
// RSA key stands in for the FCM service-account private key.

function ecP256Pem(): { privateKeyPem: string; publicKey: ReturnType<typeof createPublicKey> } {
  const { privateKey, publicKey } = generateKeyPairSync('ec', {
    namedCurve: 'P-256',
  });
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
    publicKey,
  };
}

function rsaPem(): { privateKeyPem: string; publicKey: ReturnType<typeof createPublicKey> } {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
  });
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
    publicKey,
  };
}

describe('signJwtES256 (APNs provider token)', () => {
  it('produces a structurally valid ES256 JWT whose signature verifies', () => {
    const { privateKeyPem, publicKey } = ecP256Pem();
    const iat = 1_700_000_000;
    const token = signJwtES256(
      { iss: 'TEAMID1234', iat },
      'KEYID56789',
      privateKeyPem,
    );

    const { header, claims } = decodeJwt(token);
    expect(header.alg).toBe('ES256');
    expect(header.kid).toBe('KEYID56789');
    expect(claims.iss).toBe('TEAMID1234');
    expect(claims.iat).toBe(iat);

    // Verify the JOSE (IEEE-P1363) signature over header.claims.
    const signingInput = Buffer.from(token.split('.').slice(0, 2).join('.'), 'utf8');
    const sig = Buffer.from(token.split('.')[2] as string, 'base64url');
    expect(
      nodeVerify('sha256', signingInput, { key: publicKey, dsaEncoding: 'ieee-p1363' }, sig),
    ).toBe(true);
    // ES256 signatures are raw r||s == 64 bytes (not DER).
    expect(sig.length).toBe(64);
  });
});

describe('signJwtRS256 (FCM service-account assertion)', () => {
  it('produces a valid RS256 JWT with the firebase scope claim', () => {
    const { privateKeyPem, publicKey } = rsaPem();
    const iat = 1_700_000_000;
    const token = signJwtRS256(
      {
        iss: 'svc@proj.iam.gserviceaccount.com',
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
        aud: 'https://oauth2.googleapis.com/token',
        iat,
        exp: iat + 3600,
      },
      privateKeyPem,
    );
    const { header, claims } = decodeJwt(token);
    expect(header.alg).toBe('RS256');
    expect(claims.scope).toContain('firebase.messaging');

    const signingInput = Buffer.from(token.split('.').slice(0, 2).join('.'), 'utf8');
    const sig = Buffer.from(token.split('.')[2] as string, 'base64url');
    expect(nodeVerify('sha256', signingInput, publicKey, sig)).toBe(true);
  });
});

describe('verifyEd25519', () => {
  it('verifies a mac-signed wake string and rejects tampering / wrong key', () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const macDeviceId = publicKey.export({ format: 'jwk' }).x as string;
    const message = Buffer.from(
      pushWakeSigningString({
        deviceId: 'phone-1',
        token: 'tok-1',
        platform: 'apns',
        sealedPayload: 'U0VBTEVE',
      }),
      'utf8',
    );
    const sig = nodeSign(null, message, privateKey).toString('base64url');

    expect(verifyEd25519(macDeviceId, message, sig)).toBe(true);

    // Wrong signer key.
    const otherId = generateKeyPairSync('ed25519').publicKey.export({
      format: 'jwk',
    }).x as string;
    expect(verifyEd25519(otherId, message, sig)).toBe(false);

    // Tampered message.
    const tampered = Buffer.from('different-bytes', 'utf8');
    expect(verifyEd25519(macDeviceId, tampered, sig)).toBe(false);
  });

  it('never throws on malformed input', () => {
    expect(verifyEd25519('not-a-key', Buffer.from('x'), 'not-a-sig')).toBe(false);
    expect(verifyEd25519('', Buffer.alloc(0), '')).toBe(false);
  });
});
