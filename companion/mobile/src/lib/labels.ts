/**
 * Presentation mappings for wire enums: human labels, badge colors, and tool
 * glyphs. Kept separate from components so the same mapping is reusable and the
 * enum coverage is exhaustive (a new `PaneState` fails typecheck here first).
 */
import type { ComponentProps } from 'react';
import type { Ionicons } from '@expo/vector-icons';

import type { InteractionKind, PaneState } from '@zentty/wire';

import { colors } from '@/theme';

type IoniconName = ComponentProps<typeof Ionicons>['name'];

const PANE_STATE_LABEL: Record<PaneState, string> = {
  starting: 'Starting',
  running: 'Running',
  needsInput: 'Needs input',
  unresolvedStop: 'Stopped',
  idle: 'Idle',
};

const PANE_STATE_COLOR: Record<PaneState, string> = {
  starting: colors.starting,
  running: colors.running,
  needsInput: colors.attention,
  unresolvedStop: colors.stopped,
  idle: colors.idle,
};

const INTERACTION_LABEL: Record<InteractionKind, string> = {
  none: '',
  approval: 'Approval',
  question: 'Question',
  decision: 'Decision',
  auth: 'Auth',
  genericInput: 'Input',
};

export function paneStateLabel(state: PaneState): string {
  return PANE_STATE_LABEL[state];
}

export function paneStateColor(state: PaneState): string {
  return PANE_STATE_COLOR[state];
}

export function interactionKindLabel(kind: InteractionKind): string {
  return INTERACTION_LABEL[kind];
}

/** Map a known agent CLI name to an Ionicon; everything else gets the terminal glyph. */
export function toolIconName(tool?: string): IoniconName {
  const key = (tool ?? '').toLowerCase();
  if (key.includes('claude')) return 'sparkles-outline';
  if (key.includes('codex') || key.includes('gpt') || key.includes('openai')) return 'logo-electron';
  if (key.includes('cursor')) return 'navigate-outline';
  if (key.includes('gemini')) return 'planet-outline';
  if (key.includes('kimi')) return 'moon-outline';
  if (key.includes('grok')) return 'flash-outline';
  if (key.includes('droid') || key.includes('factory')) return 'hardware-chip-outline';
  if (key.includes('agy') || key.includes('antigravity')) return 'rocket-outline';
  return 'terminal-outline';
}

/** Compact relative time: "just now", "3m ago", "2h ago", "5d ago". */
export function formatRelativeTime(ts: number, now: number = Date.now()): string {
  const seconds = Math.max(0, Math.floor((now - ts) / 1000));
  if (seconds < 10) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}
