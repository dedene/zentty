/**
 * Regenerate the session-crypto interop vector at
 * companion/wire/vectors/crypto/session-crypto.json.
 *
 * Run from companion/mobile with:  pnpm exec tsx scripts/generate-crypto-vectors.ts
 *
 * The output is deterministic, so committing it and re-running is a no-op — the
 * conformance test (src/core/__tests__/crypto-vectors.test.ts) enforces exactly
 * that. The Swift pin (ZenttyLogicTests) loads the same file and asserts CryptoKit
 * derives byte-identical values.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadSodium } from './loadSodium';
import { buildSessionCryptoVector, serializeVector } from './cryptoVectorBuilder';

async function main(): Promise<void> {
  const sodium = await loadSodium();
  const vector = buildSessionCryptoVector(sodium);
  const outPath = fileURLToPath(
    new URL('../../wire/vectors/crypto/session-crypto.json', import.meta.url),
  );
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, serializeVector(vector));
  // eslint-disable-next-line no-console
  console.log(`wrote ${outPath}`);
}

void main();
