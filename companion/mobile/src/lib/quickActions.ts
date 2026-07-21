/**
 * Structured quick-actions for a pane awaiting a human.
 *
 * Every `id` here must be one the Mac's `CompanionInputRouter.bytes(forQuickAction:)`
 * accepts (Zentty/Companion/Bridge/CompanionInputRouter.swift):
 *   - `approve` → Enter (selects the highlighted choice)
 *   - `deny`    → Escape (cancels)
 *   - `interrupt` → Ctrl-C
 *   - `option:N` → types the digits N (numbered menu preset)
 * The router also accepts `enter|submit`, `escape|cancel` aliases, but we emit the
 * canonical trio so the contract test can pin the mapping exactly.
 */

import type { InteractionKind } from '@zentty/wire';

export type QuickActionTone = 'approve' | 'deny' | 'neutral';

export interface QuickAction {
  /** Wire `actionId` sent in `input.quickAction`. */
  id: string;
  label: string;
  tone: QuickActionTone;
}

const APPROVE: QuickAction = { id: 'approve', label: 'Approve', tone: 'approve' };
const DENY: QuickAction = { id: 'deny', label: 'Deny', tone: 'deny' };
const YES: QuickAction = { id: 'approve', label: 'Yes', tone: 'approve' };
const NO: QuickAction = { id: 'deny', label: 'No', tone: 'deny' };

/** A numbered-menu preset button (`option:N`). */
export function numberedOption(n: number): QuickAction {
  return { id: `option:${n}`, label: String(n), tone: 'neutral' };
}

/** Interaction kinds that surface the quick-actions bar. */
export function hasQuickActions(kind: InteractionKind): boolean {
  return kind === 'approval' || kind === 'decision' || kind === 'question';
}

/**
 * The quick actions to offer for a pane's interaction kind. Empty for kinds the
 * bar does not cover (`none`, `auth`, `genericInput` — those use free-text input).
 */
export function quickActionsFor(kind: InteractionKind): QuickAction[] {
  switch (kind) {
    case 'approval':
      return [APPROVE, DENY];
    case 'question':
      return [YES, NO];
    case 'decision':
      // Enter selects the highlighted option; the numbered presets let the user
      // pick a specific menu item without the concrete prompt shape (v1 coarse).
      return [APPROVE, DENY, numberedOption(1), numberedOption(2), numberedOption(3)];
    default:
      return [];
  }
}
