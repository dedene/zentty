import {
  createPrivateKey,
  createPublicKey,
  sign as nodeSign,
  verify as nodeVerify,
} from 'node:crypto';

// Cryptographic primitives for the push gateway:
//   - verifyEd25519: verify a Mac's signature over a push signing string. The
//     verifying key is derived straight from the base64url deviceId (which IS the
//     raw 32-byte Ed25519 public key), mirroring the relay-auth path in crypto.ts.
//   - signJwtES256 / signJwtRS256: compact JWS builders for APNs (ES256 provider
//     token) and FCM (RS256 service-account assertion). Both use node:crypto only.

const ED25519_RAW_LEN = 32;

/**
 * Verify `sig` (base64url) over `message` using the Ed25519 public key encoded in
 * `deviceIdBase64url` (base64url of the raw 32-byte key). Never throws — a
 * malformed key, id, or signature returns false.
 */
export function verifyEd25519(
  deviceIdBase64url: string,
  message: Buffer,
  sigBase64url: string,
): boolean {
  try {
    const rawPub = Buffer.from(deviceIdBase64url, 'base64url');
    if (rawPub.length !== ED25519_RAW_LEN) {
      return false;
    }
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: rawPub.toString('base64url') },
      format: 'jwk',
    });
    const signature = Buffer.from(sigBase64url, 'base64url');
    return nodeVerify(null, message, key, signature);
  } catch {
    return false;
  }
}

function b64url(input: Buffer | string): string {
  return Buffer.from(input as string).toString('base64url');
}

function encodeSegment(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

/**
 * Build a compact JWS (`header.claims.sig`) signing `header`+`claims` with
 * `alg`. ES256 emits an IEEE-P1363 (raw r||s) signature as JOSE requires; RS256
 * emits a PKCS#1 v1.5 signature. `privateKeyPem` is a PEM (PKCS#8 or SEC1/PKCS#1).
 */
function buildJwt(
  alg: 'ES256' | 'RS256',
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  privateKeyPem: string,
): string {
  const key = createPrivateKey(privateKeyPem);
  const signingInput = `${encodeSegment({ ...header, alg })}.${encodeSegment(claims)}`;
  const data = Buffer.from(signingInput, 'utf8');
  const signature =
    alg === 'ES256'
      ? nodeSign('sha256', data, { key, dsaEncoding: 'ieee-p1363' })
      : nodeSign('sha256', data, key);
  return `${signingInput}.${b64url(signature)}`;
}

/** APNs provider token: ES256 JWS, header `{alg, kid}`, claims `{iss, iat}`. */
export function signJwtES256(
  claims: Record<string, unknown>,
  keyId: string,
  privateKeyPem: string,
): string {
  return buildJwt('ES256', { kid: keyId, typ: 'JWT' }, claims, privateKeyPem);
}

/** FCM service-account assertion: RS256 JWS, header `{alg, typ}`. */
export function signJwtRS256(
  claims: Record<string, unknown>,
  privateKeyPem: string,
): string {
  return buildJwt('RS256', { typ: 'JWT' }, claims, privateKeyPem);
}

/** Decode a compact JWS into its parsed header and claims (test/diagnostic use). */
export function decodeJwt(token: string): {
  header: Record<string, unknown>;
  claims: Record<string, unknown>;
  signature: Buffer;
} {
  const parts = token.split('.');
  if (parts.length !== 3) {
    throw new Error('malformed jwt');
  }
  const [h, c, s] = parts as [string, string, string];
  return {
    header: JSON.parse(Buffer.from(h, 'base64url').toString('utf8')),
    claims: JSON.parse(Buffer.from(c, 'base64url').toString('utf8')),
    signature: Buffer.from(s, 'base64url'),
  };
}
