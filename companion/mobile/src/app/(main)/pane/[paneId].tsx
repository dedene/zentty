import { Stack, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AppState,
  KeyboardAvoidingView,
  Platform,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import type { InputKey, PaneState } from '@zentty/wire';

import {
  ControlIndicator,
  InputBar,
  PaneTabBar,
  QuickActionsBar,
  Screen,
  StateBadge,
  TerminalView,
  ToolIcon,
  TranscriptView,
  XtermTerminalView,
  type XtermTerminalHandle,
} from '@/components';
import { measureGrid } from '@/lib/cellMetrics';
import { cleanPaneTitle } from '@/lib/labels';
import { usePaneTab } from '@/lib/usePaneTab';
import { hasQuickActions, quickActionsFor } from '@/lib/quickActions';
import {
  idleLease,
  initialTranscript,
  type PaneController,
  useCompanionStore,
} from '@/store';
import { colors, space, type } from '@/theme';

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
  const ensurePaneController = useCompanionStore((s) => s.ensurePaneController);

  const controllerRef = useRef<PaneController | undefined>(undefined);
  // Refs (not state) so the focus/AppState effects read the latest grid + focus
  // without re-subscribing on every measure; nothing renders the raw grid.
  const gridRef = useRef<{ cols: number; rows: number } | undefined>(undefined);
  const focusedRef = useRef(false);

  // Terminal rendering: prefer the streaming xterm byte lane; fall back to the
  // plain-text snapshot mirror when the Mac is too old to answer pane.bytes.attach.
  const xtermRef = useRef<XtermTerminalHandle>(null);
  const [byteLaneSupported, setByteLaneSupported] = useState(true);
  const byteLaneFallbackRef = useRef(false);
  // The mac's authoritative grid from the latest snapshot. While we mirror
  // read-only the emulator is pinned to it and letterboxed; the phone only fits
  // to its own size once it holds a control lease (then the mac follows).
  const [macGrid, setMacGrid] = useState<{ cols: number; rows: number } | undefined>(undefined);
  const inControlRef = useRef(false);

  const hasTranscript = pane?.hasTranscript ?? false;
  const { active, tabs, setTab } = usePaneTab(paneId, hasTranscript);

  const lease = runtime?.lease ?? idleLease;
  const transcript = runtime?.transcript ?? initialTranscript;
  // Gate input on actually holding the control lease. Control is now implicit
  // (acquired on entering the pane), so `held` also implies the encrypted session
  // is ready — keystrokes only reach the Mac while we hold control, and the
  // ControlIndicator explains, and offers a retry, whenever we don't.
  const inControl = lease.status === 'held';

  /**
   * Emulator sinks for the byte lane. `onGrid` carries the mac's snapshot
   * geometry and is invoked between the reset and the snapshot write, so it must
   * apply synchronously (the view queues ops in order) rather than waiting for a
   * render. It reads the lease through a ref so the sinks stay stable.
   */
  const makeByteEffects = useCallback(
    () => ({
      onWrite: (dataB64: string) => xtermRef.current?.write(dataB64),
      onReset: () => xtermRef.current?.reset(),
      onGrid: (cols: number, rows: number) => {
        setMacGrid({ cols, rows });
        if (!inControlRef.current) {
          xtermRef.current?.setGrid(cols, rows);
        }
      },
      onUnsupported: () => {
        byteLaneFallbackRef.current = true;
        setByteLaneSupported(false);
      },
    }),
    [],
  );

  // Geometry ownership follows the lease: read-only mirroring pins the emulator
  // to the mac's snapshot grid (letterboxed), holding control hands the grid back
  // to the fit addon — the one state where the mac follows the phone and
  // re-snapshots.
  const applyGeometry = useCallback(() => {
    const term = xtermRef.current;
    if (!term) {
      return;
    }
    if (inControlRef.current) {
      term.releaseGrid();
    } else if (macGrid) {
      term.setGrid(macGrid.cols, macGrid.rows);
    }
  }, [macGrid]);

  useEffect(() => {
    inControlRef.current = inControl;
    if (byteLaneSupported) {
      applyGeometry();
    }
  }, [applyGeometry, byteLaneSupported, inControl]);

  // Resolve + watch the pane on focus, and implicitly request control (spec: entering
  // a pane on the phone takes control automatically). Leaving unwatches, which drops
  // control intent and releases any lease. The actual lease.request waits for the grid
  // to be measured (fed via onMeasure -> setViewport) and the session to be ready.
  useFocusEffect(
    useCallback(() => {
      if (!deviceId) {
        return;
      }
      let cancelled = false;
      focusedRef.current = true;
      void ensurePaneController(deviceId, paneId).then((controller) => {
        if (cancelled || !controller) {
          return;
        }
        controllerRef.current = controller;
        controller.watch();
        controller.acquireControl();
        if (gridRef.current) {
          controller.setViewport(gridRef.current.cols, gridRef.current.rows);
        }
        // Opt into the streaming byte lane. The lane cold-attaches; if the Mac
        // can't speak pane.bytes.* it fires onUnsupported and we drop to the
        // plain-text TerminalView for the rest of this screen's lifetime.
        // Transient timeouts do not sticky-fallback — resync retries later.
        if (!byteLaneFallbackRef.current) {
          controller.attachBytes(makeByteEffects());
        }
      });
      return () => {
        cancelled = true;
        focusedRef.current = false;
        controllerRef.current?.unwatch();
      };
    }, [deviceId, paneId, ensurePaneController, makeByteEffects]),
  );

  // Subscribe to the transcript the first time Conversation becomes active.
  useEffect(() => {
    if (active === 'conversation' && hasTranscript && transcript.status === 'idle') {
      void controllerRef.current?.subscribeTranscript();
    }
  }, [active, hasTranscript, transcript.status]);

  // Returning to the Terminal tab: rebind sinks (WebView may have remounted) and
  // warm-resync so any bytes received while Conversation was showing are recovered.
  useEffect(() => {
    if (active !== 'terminal' || byteLaneFallbackRef.current) {
      return;
    }
    const controller = controllerRef.current;
    if (!controller || !focusedRef.current) {
      return;
    }
    controller.attachBytes(makeByteEffects());
  }, [active, makeByteEffects]);

  // Backgrounding releases control (heartbeats would otherwise stop and the Mac
  // expires the lease after ~15s anyway; releasing is the clean path so the Mac
  // restores immediately). Returning to the foreground while still on the pane
  // re-acquires control and resyncs the byte lane (chunks may have been lost
  // while suspended even if the session stayed "ready").
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      const controller = controllerRef.current;
      if (!controller) {
        return;
      }
      if (next === 'active') {
        if (focusedRef.current) {
          controller.acquireControl();
          if (gridRef.current) {
            controller.setViewport(gridRef.current.cols, gridRef.current.rows);
          }
          if (!byteLaneFallbackRef.current) {
            controller.resyncBytes();
          }
        }
      } else {
        controller.releaseControl();
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

  const onMeasure = useCallback((widthPx: number, heightPx: number) => {
    const next = measureGrid(widthPx, heightPx);
    gridRef.current = next;
    // Feed the grid to the controller: it acquires control (if wanted + idle) or,
    // while a lease is held, resizes on a genuine column change — a keyboard toggle
    // only changes height and is ignored so it doesn't spam SIGWINCH on the Mac.
    controllerRef.current?.setViewport(next.cols, next.rows);
  }, []);

  // The xterm fit addon reports the real grid; feed it straight to the lease
  // viewport (no measureGrid rounding) so the pane reflows to the emulator size.
  const onXtermResize = useCallback((cols: number, rows: number) => {
    gridRef.current = { cols, rows };
    controllerRef.current?.setViewport(cols, rows);
  }, []);

  const onRetryControl = useCallback(() => controllerRef.current?.retryControl(), []);
  const onPullTop = useCallback(() => void controllerRef.current?.fetchScrollback(), []);
  const onSubmitText = useCallback((text: string) => controllerRef.current?.sendText(text), []);
  const onKey = useCallback((key: InputKey) => controllerRef.current?.sendKey(key), []);
  const onQuickAction = useCallback((actionId: string) => controllerRef.current?.quickAction(actionId), []);

  const title = pane ? cleanPaneTitle(pane.title) || 'Pane' : 'Pane';

  return (
    <Screen edges={['bottom', 'left', 'right']} padded={false}>
      <Stack.Screen
        options={{
          headerTitleAlign: 'left',
          headerTitle: () => (
            <PaneHeaderTitle
              tool={pane?.tool}
              title={title}
              dir={pane?.workingDirectory}
              state={pane?.state}
            />
          ),
        }}
      />
      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        keyboardVerticalOffset={Platform.OS === 'ios' ? 96 : 0}
      >
        <View style={styles.container}>
          {tabs.length > 1 ? <PaneTabBar tabs={tabs} active={active} onChange={setTab} /> : null}

          <View style={styles.body}>
            {/*
              Keep both panes mounted (absolute layers) when Conversation exists so
              switching tabs does not tear down the xterm WebView — emulator state
              and in-flight byte writes would otherwise be lost on remount.
            */}
            {hasTranscript ? (
              <View
                style={[
                  styles.layer,
                  active === 'conversation' ? styles.layerVisible : styles.layerHidden,
                ]}
                pointerEvents={active === 'conversation' ? 'auto' : 'none'}
              >
                <TranscriptView transcript={transcript} />
              </View>
            ) : null}
            <View
              style={[
                hasTranscript ? styles.layer : styles.terminalStack,
                hasTranscript
                  ? active === 'conversation'
                    ? styles.layerHidden
                    : styles.layerVisible
                  : null,
              ]}
              pointerEvents={hasTranscript && active === 'conversation' ? 'none' : 'auto'}
            >
              {byteLaneSupported ? (
                <XtermTerminalView
                  ref={xtermRef}
                  onResize={onXtermResize}
                  onReady={applyGeometry}
                />
              ) : (
                <TerminalView
                  text={runtime?.text}
                  scrollbackLoading={runtime?.scrollbackLoading}
                  scrollbackError={runtime?.scrollbackError}
                  onPullTop={onPullTop}
                  onMeasure={onMeasure}
                />
              )}
            </View>
          </View>

          {quickActions.length > 0 ? (
            <View style={styles.quick}>
              <QuickActionsBar actions={quickActions} onAction={onQuickAction} />
            </View>
          ) : null}

          <ControlIndicator lease={lease} onRetry={onRetryControl} />
          <InputBar onSubmitText={onSubmitText} onKey={onKey} disabled={!inControl} />
        </View>
      </KeyboardAvoidingView>
    </Screen>
  );
}

/**
 * Navigation-bar title: the agent logo, pane title/dir, and the compact state
 * badge in one row — the whole pane identity lives in the navbar so no duplicate
 * header card is needed below it. The badge is a trailing element of this row
 * (not `headerRight`): with the text block flexing and the badge fixed, the
 * title truncates instead of ever sliding under the badge. The row is width-
 * capped because native-stack gives a custom title view an unbounded frame.
 */
function PaneHeaderTitle({
  tool,
  title,
  dir,
  state,
}: {
  tool?: string;
  title: string;
  dir?: string;
  state?: PaneState;
}) {
  const { width } = useWindowDimensions();
  // Reserve room for the native back button + leading inset so a long title/path
  // truncates before it reaches the screen edge.
  const maxWidth = width - 92;
  return (
    <View style={[styles.headerTitle, { maxWidth }]}>
      <ToolIcon tool={tool} size={26} />
      <View style={styles.headerTitleText}>
        <Text style={styles.titleLine} numberOfLines={1}>
          {title}
        </Text>
        {dir ? (
          <Text style={[type.mono, styles.dirLine]} numberOfLines={1} ellipsizeMode="head">
            {dir}
          </Text>
        ) : null}
      </View>
      {state ? <StateBadge state={state} compact /> : null}
    </View>
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
  headerTitle: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    // Reclaim the leading gap the native header reserves so the row hugs the
    // back button and gets maximum width before truncating.
    marginLeft: -space.xs,
  },
  headerTitleText: {
    flexShrink: 1,
  },
  titleLine: {
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
  },
  dirLine: {
    fontSize: 11,
    color: colors.textFaint,
  },
  body: {
    flex: 1,
  },
  terminalStack: {
    flex: 1,
    gap: space.md,
  },
  /** Full-size layer so xterm keeps real dimensions while Conversation shows. */
  layer: {
    ...StyleSheet.absoluteFill,
  },
  layerVisible: {
    opacity: 1,
    zIndex: 1,
  },
  layerHidden: {
    opacity: 0,
    zIndex: 0,
  },
  quick: {
    marginTop: space.xs,
  },
});
