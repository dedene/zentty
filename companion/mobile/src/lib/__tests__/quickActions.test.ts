import { describe, expect, it } from '@jest/globals';

import type { InteractionKind } from '@zentty/wire';

import { hasQuickActions, quickActionsFor } from '../quickActions';

/**
 * Faithful re-implementation of the Mac's
 * `CompanionInputRouter.bytes(forQuickAction:)`
 * (Zentty/Companion/Bridge/CompanionInputRouter.swift). Returns the terminal
 * bytes for an actionId, or `null` when the id is not accepted. The contract test
 * asserts every id the phone can emit is accepted here and maps to the right
 * bytes — if the Swift router changes, this mirror (and the test) must change too.
 */
function macBytesForQuickAction(actionId: string): string | null {
  switch (actionId) {
    case 'approve':
    case 'enter':
    case 'submit':
      return '\r';
    case 'deny':
    case 'escape':
    case 'cancel':
      return '';
    case 'interrupt':
      return '';
    default:
      if (actionId.startsWith('option:')) {
        const value = actionId.slice('option:'.length);
        if (value.length > 0 && /^[0-9]+$/.test(value)) {
          return value;
        }
      }
      return null;
  }
}

const KINDS: InteractionKind[] = ['none', 'approval', 'question', 'decision', 'auth', 'genericInput'];

describe('quickActionsFor — Mac contract', () => {
  it('emits only actionIds the Mac router accepts', () => {
    for (const kind of KINDS) {
      for (const action of quickActionsFor(kind)) {
        expect(macBytesForQuickAction(action.id)).not.toBeNull();
      }
    }
  });

  it('maps approve to Enter and deny to Escape', () => {
    const approval = quickActionsFor('approval');
    const approve = approval.find((a) => a.tone === 'approve');
    const deny = approval.find((a) => a.tone === 'deny');
    expect(approve?.id).toBe('approve');
    expect(deny?.id).toBe('deny');
    expect(macBytesForQuickAction(approve!.id)).toBe('\r');
    expect(macBytesForQuickAction(deny!.id)).toBe('');
  });

  it('numbered decision options map to the digit bytes', () => {
    const decision = quickActionsFor('decision');
    const options = decision.filter((a) => a.id.startsWith('option:'));
    expect(options.map((o) => o.id)).toEqual(['option:1', 'option:2', 'option:3']);
    expect(macBytesForQuickAction('option:2')).toBe('2');
  });

  it('offers no quick actions for kinds that use free-text input', () => {
    expect(quickActionsFor('none')).toEqual([]);
    expect(quickActionsFor('auth')).toEqual([]);
    expect(quickActionsFor('genericInput')).toEqual([]);
  });

  it('hasQuickActions gates exactly the interactive kinds', () => {
    expect(hasQuickActions('approval')).toBe(true);
    expect(hasQuickActions('question')).toBe(true);
    expect(hasQuickActions('decision')).toBe(true);
    expect(hasQuickActions('none')).toBe(false);
    expect(hasQuickActions('auth')).toBe(false);
    expect(hasQuickActions('genericInput')).toBe(false);
  });
});
