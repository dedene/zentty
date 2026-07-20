import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  RELAY_FRAME_TYPES,
  canonicalStringify,
  parseRelayFrame,
  safeParseRelayFrame,
} from '../src/index';

interface VectorCase {
  name: string;
  valid: boolean;
  message: unknown;
}

const vectorsDir = fileURLToPath(new URL('../vectors/', import.meta.url));
const files = readdirSync(vectorsDir)
  .filter((f) => f.endsWith('.json') && f.startsWith('relay.'))
  .sort();

function load(file: string): VectorCase[] {
  return JSON.parse(readFileSync(vectorsDir + file, 'utf8')) as VectorCase[];
}

describe('relay vector coverage', () => {
  const typesWithVectors = new Set(files.map((f) => f.replace(/\.json$/, '')));

  it('every registered relay frame type has a vector file', () => {
    const missing = RELAY_FRAME_TYPES.filter((t) => !typesWithVectors.has(t));
    expect(missing).toEqual([]);
  });

  it('every relay vector file maps to a registered relay frame type', () => {
    const orphans = [...typesWithVectors].filter(
      (t) =>
        !RELAY_FRAME_TYPES.includes(t as (typeof RELAY_FRAME_TYPES)[number]),
    );
    expect(orphans).toEqual([]);
  });

  it('every relay vector file has at least one valid case', () => {
    for (const file of files) {
      const cases = load(file);
      expect(cases.some((c) => c.valid), `${file} needs a valid case`).toBe(
        true,
      );
    }
  });
});

for (const file of files) {
  describe(file, () => {
    const cases = load(file);
    for (const c of cases) {
      it(c.name, () => {
        const result = safeParseRelayFrame(c.message);
        if (c.valid) {
          if (!result.success) {
            throw result.error;
          }
          // Canonical re-encode must be byte-stable across a parse round-trip:
          // the same cross-language contract the Swift suite mirrors.
          const parsed = parseRelayFrame(c.message);
          const once = canonicalStringify(parsed);
          const twice = canonicalStringify(parseRelayFrame(JSON.parse(once)));
          expect(twice).toBe(once);
        } else {
          expect(result.success).toBe(false);
        }
      });
    }
  });
}
