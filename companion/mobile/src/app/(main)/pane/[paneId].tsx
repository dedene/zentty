import { Stack, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, KeyboardAvoidingView, Platform, StyleSheet, Text, View } from 'react-native';

import type { InputKey } from '@zentty/wire';

import {
  InputBar,
  PaneTabBar,
  QuickActionsBar,
  Screen,
  StateBadge,
  TakeoverControls,
  TerminalView,
  ToolIcon,
  TranscriptView,
} from '@/components';
import { measureGrid } from '@/lib/cellMetrics';
import { usePaneTab } from '@/lib/usePaneTab';
import { hasQuickActions, quickActionsFor } from '@/lib/quickActions';
import {
  idleLease,
  initialTranscript,
  type PaneController,
  useCompanionStore,
} from '@/store';
import { space, type } from '@/theme';

/**
 * Pane detail: a live Terminal mirror (with takeover) and, for adapted tools, a
 * Conversation transcript — with a quick-actions bar and input pinned in both
 * tabs. Drives a per-pane {@link PaneController} resolved on focus; its runtime
 * state streams in through the store.
 */
export default function PaneDetailScreen() {
  const { paneId, deviceId } = useLocalSearchParams<{ paneId: string; deviceId?: string }>();

  const pane = useCompanionStore((s) => {
    const view = deviceId ? s.views[deviceId] : undefined;
    for (const worklane of view?.worklanes ?? []) {
      const found = worklane.panes.find((p) => p.paneId === paneId);
      if (found) {
        return found;
      }
    }
    return undefined;
  });
  const runtime = useCompanionStore((s) => (deviceId ? s.views[deviceId]?.panes?.[paneId] : undefined));
  const status = useCompanionStore((s) => (deviceId ? s.views[deviceId]?.status : undefined));
  const ensurePaneController = useCompanionStore((s) => s.ensurePaneController);

  const controllerRef = useRef<PaneController | undefined>(undefined);
  const [grid, setGrid] = useState<{ cols: number; rows: number } | undefined>(undefined);

  const hasTranscript = pane?.hasTranscript ?? false;
  const { active, tabs, setTab } = usePaneTab(paneId, hasTranscript);

  const lease = runtime?.lease ?? idleLease;
  const transcript = runtime?.transcript ?? initialTranscript;
  const ready = status === 'connected';

  // Resolve + watch the pane on focus; unwatch (and release any lease) on blur.
  useFocusEffect(
    useCallback(() => {
      if (!deviceId) {
        return;
      }
      let cancelled = false;
      void ensurePaneController(deviceId, paneId).then((controller) => {
        if (cancelled || !controller) {
          return;
        }
        controllerRef.current = controller;
        controller.watch();
      });
      return () => {
        cancelled = true;
        controllerRef.current?.unwatch();
      };
    }, [deviceId, paneId, ensurePaneController]),
  );

  // Subscribe to the transcript the first time Conversation becomes active.
  useEffect(() => {
    if (active === 'conversation' && hasTranscript && transcript.status === 'idle') {
      void controllerRef.current?.subscribeTranscript();
    }
  }, [active, hasTranscript, transcript.status]);

  // Backgrounding releases control (heartbeats would otherwise stop and expire it
  // anyway; releasing is the clean path so the Mac restores immediately).
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      if (next !== 'active') {
        controllerRef.current?.releaseLease();
      }
    });
    return () => sub.remove();
  }, []);

  const quickActions = useMemo(
    () =>
      pane && pane.requiresHumanAttention && hasQuickActions(pane.interactionKind)
        ? quickActionsFor(pane.interactionKind)
        : [],
    [pane],
  );

  const onMeasure = useCallback(
    (widthPx: number, heightPx: number) => {
      const next = measureGrid(widthPx, heightPx);
      setGrid(next);
      // Rotation/font while holding a lease: re-request the grid (debounced).
      if (controllerRef.current && lease.status === 'held') {
        controllerRef.current.resizeLease(next.cols, next.rows);
      }
    },
    [lease.status],
  );

  const onTakeControl = useCallback(() => {
    if (grid) {
      controllerRef.current?.requestLease(grid.cols, grid.rows);
    }
  }, [grid]);

  const onRelease = useCallback(() => controllerRef.current?.releaseLease(), []);
  const onPullTop = useCallback(() => void controllerRef.current?.fetchScrollback(), []);
  const onSubmitText = useCallback((text: string) => controllerRef.current?.sendText(text), []);
  const onKey = useCallback((key: InputKey) => controllerRef.current?.sendKey(key), []);
  const onQuickAction = useCallback((actionId: string) => controllerRef.current?.quickAction(actionId), []);

  const title = pane?.title || 'Pane';

  return (
    <Screen edges={['bottom', 'left', 'right']} padded={false}>
      <Stack.Screen options={{ title }} />
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? 96 : 0}
      >
        <View style={styles.container}>
          <View style={styles.header}>
            <ToolIcon tool={pane?.tool} />
            <View style={styles.headerText}>
              <Text style={type.rowTitle} numberOfLines={1}>
                {title}
              </Text>
              {pane ? (
                <Text style={[type.mono, styles.dir]} numberOfLines={1}>
                  {pane.workingDirectory}
                </Text>
              ) : null}
            </View>
            {pane ? <StateBadge state={pane.state} /> : null}
          </View>

          {tabs.length > 1 ? <PaneTabBar tabs={tabs} active={active} onChange={setTab} /> : null}

          <View style={styles.body}>
            {active === 'conversation' && hasTranscript ? (
              <TranscriptView transcript={transcript} />
            ) : (
              <View style={styles.terminalStack}>
                <TerminalView
                  text={runtime?.text}
                  scrollbackLoading={runtime?.scrollbackLoading}
                  onPullTop={onPullTop}
                  onMeasure={onMeasure}
                />
                <TakeoverControls
                  lease={lease}
                  grid={grid}
                  demoted={hasTranscript}
                  onTakeControl={onTakeControl}
                  onRelease={onRelease}
                />
              </View>
            )}
          </View>

          {quickActions.length > 0 ? (
            <View style={styles.quick}>
              <QuickActionsBar actions={quickActions} onAction={onQuickAction} />
            </View>
          ) : null}

          <InputBar onSubmitText={onSubmitText} onKey={onKey} disabled={!ready} />
        </View>
      </KeyboardAvoidingView>
    </Screen>
  );
}

const styles = StyleSheet.create({
  flex: {
    flex: 1,
  },
  container: {
    flex: 1,
    padding: space.lg,
    gap: space.md,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  headerText: {
    flex: 1,
    gap: 2,
  },
  dir: {
    fontSize: 12,
  },
  body: {
    flex: 1,
  },
  terminalStack: {
    flex: 1,
    gap: space.md,
  },
  quick: {
    marginTop: space.xs,
  },
});
