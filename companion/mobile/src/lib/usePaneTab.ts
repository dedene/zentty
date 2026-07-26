/**
 * Sticky per-pane tab selection. Reads the last-used tab from persisted storage
 * on mount, coerces a stale `conversation` choice back to Terminal when the pane
 * no longer has a transcript, and writes the choice back on every switch.
 */
import { useCallback, useEffect, useState } from 'react';

import { getStorage } from '@/runtime/storage';
import { availableTabs, paneTabPreferenceKey, parsePaneTab, resolveActiveTab, type PaneTab } from '@/store';

export function usePaneTab(paneId: string, hasTranscript: boolean): {
  active: PaneTab;
  tabs: PaneTab[];
  setTab: (tab: PaneTab) => void;
} {
  const [active, setActive] = useState<PaneTab>('terminal');

  // Load the stored preference once per pane.
  useEffect(() => {
    let cancelled = false;
    void getStorage()
      .then((storage) => storage.getPreference(paneTabPreferenceKey(paneId)))
      .then((stored) => {
        if (!cancelled) {
          setActive(resolveActiveTab(parsePaneTab(stored), hasTranscript));
        }
      });
    return () => {
      cancelled = true;
    };
    // hasTranscript intentionally omitted: the coercion effect below handles it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paneId]);

  // If the transcript disappears while Conversation is active, fall back.
  useEffect(() => {
    setActive((current) => resolveActiveTab(current, hasTranscript));
  }, [hasTranscript]);

  const setTab = useCallback(
    (tab: PaneTab) => {
      setActive(tab);
      void getStorage().then((storage) => storage.setPreference(paneTabPreferenceKey(paneId), tab));
    },
    [paneId],
  );

  return { active, tabs: availableTabs(hasTranscript), setTab };
}
