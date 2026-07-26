import { describe, expect, it } from '@jest/globals';

import { availableTabs, parsePaneTab, resolveActiveTab } from '../paneTabs';

describe('availableTabs', () => {
  it('shows only Terminal when the pane has no transcript', () => {
    expect(availableTabs(false)).toEqual(['terminal']);
  });

  it('shows Conversation only when the pane has a transcript', () => {
    expect(availableTabs(true)).toEqual(['terminal', 'conversation']);
    expect(availableTabs(true)).toContain('conversation');
    expect(availableTabs(false)).not.toContain('conversation');
  });
});

describe('resolveActiveTab', () => {
  it('keeps a sticky conversation choice when a transcript exists', () => {
    expect(resolveActiveTab('conversation', true)).toBe('conversation');
  });

  it('falls back to Terminal when conversation is unavailable', () => {
    expect(resolveActiveTab('conversation', false)).toBe('terminal');
  });

  it('defaults to Terminal with no stored preference', () => {
    expect(resolveActiveTab(undefined, true)).toBe('terminal');
    expect(resolveActiveTab(undefined, false)).toBe('terminal');
  });

  it('honors a stored terminal choice', () => {
    expect(resolveActiveTab('terminal', true)).toBe('terminal');
  });
});

describe('parsePaneTab', () => {
  it('accepts the two known tabs', () => {
    expect(parsePaneTab('terminal')).toBe('terminal');
    expect(parsePaneTab('conversation')).toBe('conversation');
  });

  it('rejects unknown / missing values', () => {
    expect(parsePaneTab('nonsense')).toBeUndefined();
    expect(parsePaneTab(null)).toBeUndefined();
    expect(parsePaneTab(undefined)).toBeUndefined();
  });
});
