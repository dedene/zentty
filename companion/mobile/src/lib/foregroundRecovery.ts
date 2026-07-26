/**
 * Foreground recovery, subscribed once by the root layout for the app lifetime.
 * iOS suspends sockets and timers while backgrounded, so on return a connection
 * can sit in a residual reconnect backoff with a stale session. Each foreground
 * nudges every known Mac connection awake, and retries hydration when it
 * previously failed (e.g. a transient SecureStore error at launch).
 *
 * Mirrors the AppState-listener pattern in `app/(main)/pane/[paneId].tsx`, but
 * lives app-wide rather than per screen.
 */
import { AppState } from 'react-native';

import { useCompanionStore } from '@/store';

/** Returns an unsubscribe function. */
export function subscribeForegroundRecovery(): () => void {
  const sub = AppState.addEventListener('change', (next) => {
    if (next !== 'active') {
      return;
    }
    const { ready, hydrate, wakeConnections } = useCompanionStore.getState();
    if (!ready) {
      // Swallow the failure: the next foreground (or launch retry) tries again.
      void hydrate().catch(() => undefined);
    }
    wakeConnections();
  });
  return () => sub.remove();
}
