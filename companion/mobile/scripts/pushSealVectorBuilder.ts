/**
 * Deterministic builder for the push-seal interop vector, shared by the generator
 * and the conformance test. Fixed, test-only keys + a fixed nonce make it a
 * byte-identical "regenerate is a no-op" artifact, exactly like the session-crypto
 * vector.
 *
 * This is the PHONE side's expectation of the push-seal scheme. The Mac's push
 * seal (CryptoKit: Curve25519 key agreement + HKDF<SHA256> + ChaChaPoly) must
 * reproduce `expected.pushKey` and open `expected.sealedSample.sealed` to the same
 * plaintext. Until the Mac pins this file, treat it as the phone's proposal to be
 * cross-checked.
 *
 * WARNING: the private keys below are throwaway test vectors — never reuse.
 */

import { encodeBase64Url } from '../src/core/base64url';
import { PUSH_SEAL_LABEL, derivePushKey, sealPush } from '../src/core/pushCrypto';
import type { SodiumLike } from '../src/core/sodium';

// Fixed test-only Ed25519 identity seeds (32-byte raw) and a fixed 12-byte nonce.
const MAC_IDENTITY_PRIV_HEX =
  '1e4004aa516193bc955e8c716eee47e60294613dea353581f25051cc34aac92c';
const PHONE_IDENTITY_PRIV_HEX =
  'c4969bf09cdcc7f7fbdee3753c54d74349dd7082cafb424bab88f155ba4096f7';
const NONCE_HEX = '000102030405060708090a0b';

// A representative decrypted wake payload: the pane the agent needs attention on.
const SAMPLE_PLAINTEXT = JSON.stringify({
  paneId: 'pane-7',
  worklaneId: 'wl-2',
  title: 'Claude needs your approval',
  body: 'Run tests in ~/code/app?',
});

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export interface PushSealVector {
  description: string;
  label: string;
  keys: {
    macIdentityPriv: string;
    phoneIdentityPriv: string;
  };
  derivedPublicKeys: {
    macIdentityPub: string;
    phoneIdentityPub: string;
  };
  expected: {
    pushKey: string;
    sealedSample: {
      plaintext: string;
      nonce: string;
      /** base64url of `nonce || ciphertext || tag`. */
      sealed: string;
    };
  };
}

/** Compute the full push-seal vector from the fixed keys. */
export function buildPushSealVector(sodium: SodiumLike): PushSealVector {
  const macIdentitySeed = fromHex(MAC_IDENTITY_PRIV_HEX);
  const phoneIdentitySeed = fromHex(PHONE_IDENTITY_PRIV_HEX);
  const nonce = fromHex(NONCE_HEX);

  const macIdentityPub = sodium.signSeedKeypair(macIdentitySeed).publicKey;
  const phoneIdentityPub = sodium.signSeedKeypair(phoneIdentitySeed).publicKey;

  const pushKey = derivePushKey(sodium, {
    macIdentityPublicKey: macIdentityPub,
    phoneIdentitySeed,
  });
  const sealed = sealPush(sodium, pushKey, nonce, new TextEncoder().encode(SAMPLE_PLAINTEXT));

  return {
    description:
      'Zentty companion push-seal interop vector (PHONE side). TEST-ONLY private ' +
      'keys — never reuse. Key = HKDF-SHA256(X25519(macIdentity, phoneIdentity), ' +
      'salt="zentty-push/v1", info="zentty-push"), sealed = ' +
      'nonce||ChaCha20-Poly1305-IETF. The Mac push seal (CryptoKit) must ' +
      'reproduce pushKey and open sealedSample.',
    label: PUSH_SEAL_LABEL,
    keys: {
      macIdentityPriv: encodeBase64Url(macIdentitySeed),
      phoneIdentityPriv: encodeBase64Url(phoneIdentitySeed),
    },
    derivedPublicKeys: {
      macIdentityPub: encodeBase64Url(macIdentityPub),
      phoneIdentityPub: encodeBase64Url(phoneIdentityPub),
    },
    expected: {
      pushKey: encodeBase64Url(pushKey),
      sealedSample: {
        plaintext: SAMPLE_PLAINTEXT,
        nonce: encodeBase64Url(nonce),
        sealed: encodeBase64Url(sealed),
      },
    },
  };
}

/** Canonical on-disk serialization (2-space JSON + trailing newline). */
export function serializePushSealVector(vector: PushSealVector): string {
  return `${JSON.stringify(vector, null, 2)}\n`;
}
