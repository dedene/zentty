import { generateKeyPairSync, sign } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  RELAY_AUTH_PREFIX,
  classifySealed,
  verifyRelayAuth,
} from '../src/crypto.js';

// The Swift/CryptoKit and react-native-libsodium sides must interop with this
// exact verification: raw 32-byte Ed25519 pubkeys as unpadded base64url (also
// the deviceId), signature over UTF-8 `"zentty-relay-auth:" + nonce`.

/** Frozen fixture matching companion/wire/vectors/relay.auth.json. */
const VECTOR = {
  deviceId: 'mUhoCMEvQkPzIzTfLY2gKLowTnv7ph_gVsRVF-6fEho',
  pubKey: 'mUhoCMEvQkPzIzTfLY2gKLowTnv7ph_gVsRVF-6fEho',
  sig: 's13340AnvgblPQCSfKLdy6h8lxEDm2kAumQDrM2PKHV6xoVB01xczLrDiCvuUD1F2IGMbuf9LIcsabgI4eObCA',
  nonce: 'dyrw8VrNk9NNAXV2yU0fw0sNjUec8hTeR7JtwG5h5cE',
};

describe('verifyRelayAuth', () => {
  it('has the domain-separated prefix the Swift side signs', () => {
    expect(RELAY_AUTH_PREFIX).toBe('zentty-relay-auth:');
  });

  it('accepts the frozen wire vector', () => {
    expect(
      verifyRelayAuth(
        { deviceId: VECTOR.deviceId, pubKey: VECTOR.pubKey, sig: VECTOR.sig },
        VECTOR.nonce,
      ),
    ).toBe(true);
  });

  it('rejects the vector under a different nonce', () => {
    expect(
      verifyRelayAuth(
        { deviceId: VECTOR.deviceId, pubKey: VECTOR.pubKey, sig: VECTOR.sig },
        'a-different-nonce',
      ),
    ).toBe(false);
  });

  it('round-trips a freshly generated key', () => {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const raw = publicKey.export({ format: 'jwk' }).x as string;
    const nonce = 'freshNonce_09-AZ';
    const sig = sign(
      null,
      Buffer.from(RELAY_AUTH_PREFIX + nonce, 'utf8'),
      privateKey,
    ).toString('base64url');
    expect(verifyRelayAuth({ deviceId: raw, pubKey: raw, sig }, nonce)).toBe(
      true,
    );
  });

  it('rejects when deviceId does not match the presented pubKey', () => {
    const other = generateKeyPairSync('ed25519').publicKey.export({
      format: 'jwk',
    }).x as string;
    expect(
      verifyRelayAuth(
        { deviceId: other, pubKey: VECTOR.pubKey, sig: VECTOR.sig },
        VECTOR.nonce,
      ),
    ).toBe(false);
  });

  it('rejects a malformed (non-32-byte) public key', () => {
    expect(
      verifyRelayAuth(
        { deviceId: 'short', pubKey: 'short', sig: VECTOR.sig },
        VECTOR.nonce,
      ),
    ).toBe(false);
  });
});

describe('classifySealed', () => {
  it('flags a plaintext pairing envelope', () => {
    const sealed = Buffer.from(
      JSON.stringify({ v: 1, id: 'x', type: 'pairing.request', payload: {} }),
      'utf8',
    ).toString('base64url');
    const result = classifySealed(sealed, 4096);
    expect(result.isPairing).toBe(true);
    expect(result.pairingTooLarge).toBe(false);
  });

  it('marks an oversized pairing envelope', () => {
    const big = 'x'.repeat(5000);
    const sealed = Buffer.from(
      JSON.stringify({ v: 1, id: big, type: 'pairing.request', payload: {} }),
      'utf8',
    ).toString('base64url');
    expect(classifySealed(sealed, 4096).pairingTooLarge).toBe(true);
  });

  it('treats an encrypted (non-JSON) blob as non-pairing', () => {
    const sealed = Buffer.from([0x00, 0x01, 0xff, 0x7a]).toString('base64url');
    expect(classifySealed(sealed, 4096).isPairing).toBe(false);
  });

  it('treats a non-pairing envelope as non-pairing', () => {
    const sealed = Buffer.from(
      JSON.stringify({ type: 'session.ping' }),
      'utf8',
    ).toString('base64url');
    expect(classifySealed(sealed, 4096).isPairing).toBe(false);
  });
});
