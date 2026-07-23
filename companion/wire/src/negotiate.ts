import type { VersionRange } from './types';

/**
 * Negotiate the effective protocol version from two advertised windows.
 *
 * Effective = min(a.max, b.max). Returns `null` when that value falls below
 * either side's minimum, meaning the peers are incompatible and the session
 * must abort.
 */
export function negotiateVersion(
  a: VersionRange,
  b: VersionRange,
): number | null {
  const effective = Math.min(a.max, b.max);
  if (effective < a.min || effective < b.min) {
    return null;
  }
  return effective;
}
