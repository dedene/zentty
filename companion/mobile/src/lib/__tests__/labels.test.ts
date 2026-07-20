import { describe, expect, it } from '@jest/globals';

import {
  formatRelativeTime,
  interactionKindLabel,
  paneStateLabel,
  toolIconName,
} from '../labels';

describe('formatRelativeTime', () => {
  const now = 1_000_000_000_000;

  it('reads recent moments as "just now"', () => {
    expect(formatRelativeTime(now - 3_000, now)).toBe('just now');
  });

  it('steps up through seconds, minutes, hours, and days', () => {
    expect(formatRelativeTime(now - 30_000, now)).toBe('30s ago');
    expect(formatRelativeTime(now - 5 * 60_000, now)).toBe('5m ago');
    expect(formatRelativeTime(now - 3 * 3_600_000, now)).toBe('3h ago');
    expect(formatRelativeTime(now - 2 * 86_400_000, now)).toBe('2d ago');
  });

  it('never renders negative time for a future timestamp', () => {
    expect(formatRelativeTime(now + 10_000, now)).toBe('just now');
  });
});

describe('toolIconName', () => {
  it('maps known agents to distinct glyphs', () => {
    expect(toolIconName('claude')).toBe('sparkles-outline');
    expect(toolIconName('Codex')).toBe('logo-electron');
  });

  it('falls back to the terminal glyph for unknown or missing tools', () => {
    expect(toolIconName('some-random-shell')).toBe('terminal-outline');
    expect(toolIconName(undefined)).toBe('terminal-outline');
  });
});

describe('enum labels', () => {
  it('labels pane states and interaction kinds for display', () => {
    expect(paneStateLabel('needsInput')).toBe('Needs input');
    expect(paneStateLabel('unresolvedStop')).toBe('Stopped');
    expect(interactionKindLabel('approval')).toBe('Approval');
    expect(interactionKindLabel('none')).toBe('');
  });
});
