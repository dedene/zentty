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

import { AGENT_ICON_SVG, type AgentIconKey } from './agentIcons';

/**
 * Resolve an agent CLI name to one of the desktop app's logos (rendered by
 * {@link ToolIcon}). Order matters: match more specific names before broad
 * substrings. Returns undefined for unknown tools, which fall back to a glyph.
 */
export function agentIconKey(tool?: string): AgentIconKey | undefined {
  const key = (tool ?? '').toLowerCase();
  if (!key) return undefined;
  if (key.includes('claude')) return 'claudeCode';
  if (key.includes('codex') || key.includes('openai') || key.includes('gpt')) return 'codex';
  if (key.includes('copilot')) return 'copilot';
  if (key.includes('cursor')) return 'cursor';
  if (key.includes('droid') || key.includes('factory')) return 'droid';
  if (key.includes('gemini')) return 'gemini';
  if (key.includes('grok')) return 'grok';
  if (key.includes('hermes')) return 'hermes';
  if (key.includes('kimi')) return 'kimi';
  if (key.includes('mistral')) return 'mistral';
  if (key.includes('opencode')) return 'openCode';
  if (key.includes('amp')) return 'amp';
  if (key === 'pi' || key.includes('pi ') || key.includes('pi-') || key.includes('pomp')) return 'pi';
  if (key.includes('zentty')) return 'zentty';
  return undefined;
}

/** The SVG markup for a tool's logo, or undefined when there's no known logo. */
export function agentIconSvg(tool?: string): string | undefined {
  const k = agentIconKey(tool);
  return k ? AGENT_ICON_SVG[k] : undefined;
}

/** Fallback Ionicon for tools without a bundled logo — the terminal glyph. */
export function toolIconName(tool?: string): IoniconName {
  const key = (tool ?? '').toLowerCase();
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

/**
 * True when `cp` is part of a leading agent/emoji glyph we want to drop from a
 * pane title. Covers the emoji planes agents actually prefix with (Claude's
 * `✳`, spinners, status dots) plus the joiners/modifiers that bind a cluster
 * together (ZWJ, variation selectors, skin-tone modifiers, regional
 * indicators). Deliberately leading-only — see {@link cleanPaneTitle}.
 */
function isLeadingGlyphCodePoint(cp: number): boolean {
  return (
    cp === 0x200d || // zero-width joiner
    (cp >= 0xfe00 && cp <= 0xfe0f) || // variation selectors
    (cp >= 0x2190 && cp <= 0x21ff) || // arrows
    (cp >= 0x2300 && cp <= 0x23ff) || // misc technical (⌛ ⏳ …)
    (cp >= 0x2600 && cp <= 0x27bf) || // misc symbols + dingbats (✳ ✅ …)
    (cp >= 0x2b00 && cp <= 0x2bff) || // stars, arrows (⭐ ⬛ …)
    (cp >= 0x1f000 && cp <= 0x1faff) // emoji supplementary planes
  );
}

/**
 * Strip a leading emoji/agent-glyph cluster (and the whitespace after it) from a
 * pane title. The desktop app derives titles from the terminal's own title,
 * which agents frequently prefix with a status glyph (e.g. `✳ Refactoring`);
 * the mobile UI already shows the agent logo in its own tile, so the embedded
 * glyph is a duplicate. Defensive: only strips a genuine leading glyph run, and
 * never returns an empty string (falls back to the original title).
 */
export function cleanPaneTitle(title: string): string {
  const chars = Array.from(title);
  let i = 0;
  while (i < chars.length && isLeadingGlyphCodePoint(chars[i].codePointAt(0) ?? 0)) {
    i += 1;
  }
  if (i === 0) {
    return title;
  }
  const rest = chars.slice(i).join('').replace(/^\s+/, '');
  return rest.length > 0 ? rest : title;
}
