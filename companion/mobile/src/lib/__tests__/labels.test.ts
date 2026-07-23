import { describe, expect, it } from '@jest/globals';

import {
  agentIconKey,
  agentIconSvg,
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

describe('agentIconKey', () => {
  it('resolves known agent CLIs to their bundled logo', () => {
    expect(agentIconKey('claude')).toBe('claudeCode');
    expect(agentIconKey('Claude Code')).toBe('claudeCode');
    expect(agentIconKey('Codex')).toBe('codex');
    expect(agentIconKey('gpt-5.5')).toBe('codex');
    expect(agentIconKey('cursor-agent')).toBe('cursor');
    expect(agentIconKey('Gemini')).toBe('gemini');
    expect(agentIconKey('grok')).toBe('grok');
    expect(agentIconKey('opencode')).toBe('openCode');
  });

  it('returns undefined for unknown or missing tools', () => {
    expect(agentIconKey('some-random-shell')).toBeUndefined();
    expect(agentIconKey(undefined)).toBeUndefined();
    expect(agentIconKey('')).toBeUndefined();
  });

  it('exposes real SVG markup for a known tool and nothing for unknown', () => {
    expect(agentIconSvg('claude')).toContain('<svg');
    expect(agentIconSvg('some-random-shell')).toBeUndefined();
  });
});

describe('toolIconName', () => {
  it('falls back to the terminal glyph for tools without a bundled logo', () => {
    expect(toolIconName('some-random-shell')).toBe('terminal-outline');
    expect(toolIconName(undefined)).toBe('terminal-outline');
  });

  it('keeps a distinct glyph for Antigravity, which has no logo yet', () => {
    expect(toolIconName('antigravity')).toBe('rocket-outline');
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
