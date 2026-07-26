/**
 * Canonical JSON encoding: recursively sort object keys and drop `undefined`
 * values so both the TS and Swift suites can re-encode any vector to a
 * byte-stable form regardless of original field order.
 */
export function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value !== null && typeof value === 'object') {
    const source = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) {
      const child = source[key];
      if (child === undefined) {
        continue;
      }
      out[key] = canonicalize(child);
    }
    return out;
  }
  return value;
}

export function canonicalStringify(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}
