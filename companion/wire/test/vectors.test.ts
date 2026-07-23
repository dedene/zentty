import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  MESSAGE_TYPES,
  canonicalStringify,
  parseMessage,
  safeParseMessage,
} from '../src/index';

interface VectorCase {
  name: string;
  valid: boolean;
  message: unknown;
}

const vectorsDir = fileURLToPath(new URL('../vectors/', import.meta.url));
// `relay.*.json` vectors validate the relay transport framing, not the E2E
// envelope, and are covered by relay-vectors.test.ts against RELAY_FRAME. Keep
// them out of the envelope registry coverage here.
const files = readdirSync(vectorsDir)
  .filter((f) => f.endsWith('.json') && !f.startsWith('relay.'))
  .sort();

function load(file: string): VectorCase[] {
  return JSON.parse(readFileSync(vectorsDir + file, 'utf8')) as VectorCase[];
}

describe('vector coverage', () => {
  const typesWithVectors = new Set(files.map((f) => f.replace(/\.json$/, '')));

  it('every registered message type has a vector file', () => {
    const missing = MESSAGE_TYPES.filter((t) => !typesWithVectors.has(t));
    expect(missing).toEqual([]);
  });

  it('every vector file maps to a registered message type', () => {
    const orphans = [...typesWithVectors].filter(
      (t) => !MESSAGE_TYPES.includes(t as (typeof MESSAGE_TYPES)[number]),
    );
    expect(orphans).toEqual([]);
  });

  it('every vector file has at least one valid case', () => {
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
        const result = safeParseMessage(c.message);
        if (c.valid) {
          if (!result.success) {
            throw result.error;
          }
          // Canonical re-encode must be byte-stable across a parse round-trip:
          // this is the cross-language contract the Swift suite mirrors.
          const parsed = parseMessage(c.message);
          const once = canonicalStringify(parsed);
          const twice = canonicalStringify(parseMessage(JSON.parse(once)));
          expect(twice).toBe(once);
        } else {
          expect(result.success).toBe(false);
        }
      });
    }
  });
}
