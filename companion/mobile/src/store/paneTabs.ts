/**
 * Pane-detail tab model. The Terminal tab exists for every pane; the
 * Conversation tab appears only when the pane has an adapter-backed transcript
 * (`hasTranscript`). The user's last-used tab is sticky per pane, but a stored
 * `conversation` choice must gracefully fall back to Terminal when the pane no
 * longer has a transcript.
 */

export type PaneTab = 'terminal' | 'conversation';

/** Tabs to render, in bar order. Conversation only when a transcript exists. */
export function availableTabs(hasTranscript: boolean): PaneTab[] {
  return hasTranscript ? ['terminal', 'conversation'] : ['terminal'];
}

/** The tab to show: the sticky preference when still available, else Terminal. */
export function resolveActiveTab(
  preferred: PaneTab | undefined,
  hasTranscript: boolean,
): PaneTab {
  return preferred === 'conversation' && hasTranscript ? 'conversation' : 'terminal';
}

/** Persisted-preference key for a pane's last-used tab. */
export function paneTabPreferenceKey(paneId: string): string {
  return `paneTab:${paneId}`;
}

/** Narrow an arbitrary stored string back to a {@link PaneTab}. */
export function parsePaneTab(value: string | undefined | null): PaneTab | undefined {
  return value === 'terminal' || value === 'conversation' ? value : undefined;
}
