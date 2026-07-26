import {
  forwardRef,
  useCallback,
  useImperativeHandle,
  useMemo,
  useRef,
} from 'react';
import { type LayoutChangeEvent, StyleSheet, View } from 'react-native';
import { WebView, type WebViewMessageEvent } from 'react-native-webview';

import { colors } from '@/theme';

import { XTERM_HTML } from './xterm/xtermHtml.generated';

/** Imperative surface the pane screen drives the emulator through. */
export interface XtermTerminalHandle {
  /** Feed one run of standard-base64 PTY bytes to the emulator. */
  write(dataB64: string): void;
  /** Discard emulator state (fresh baseline before a replay). */
  reset(): void;
  /**
   * Pin the emulator to the mac's authoritative grid and letterbox it into the
   * available space. Disables the fit addon: while mirroring read-only the mac
   * owns the geometry, so the phone must not renegotiate it. Queued in order
   * with {@link reset}/{@link write} so a snapshot lands at the right size.
   */
  setGrid(cols: number, rows: number): void;
  /**
   * Hand the grid back to the phone: re-enable the fit addon and report the
   * fitted size. Only valid while a control lease is held — that is the one
   * state where the mac follows the phone's size (and re-snapshots).
   */
  releaseGrid(): void;
}

export interface XtermTerminalViewProps {
  /** Fired once the emulator has booted and can accept writes. */
  onReady?: () => void;
  /** Fired with the fit-computed grid whenever the terminal is (re)sized. */
  onResize?: (cols: number, rows: number) => void;
  /** Font size in px; defaults to the app's terminal cell size. */
  fontSize?: number;
  /** Scrollback line budget inside the emulator. */
  scrollback?: number;
}

/** xterm theme mapped from the app's dark design tokens. */
const XTERM_THEME = {
  background: '#05070A',
  foreground: colors.text,
  cursor: colors.accent,
  cursorAccent: '#05070A',
  selectionBackground: 'rgba(91,157,249,0.35)',
  black: '#0B0D10',
  red: '#FF5C5C',
  green: '#3FB950',
  yellow: '#F5A623',
  blue: '#5B9DF9',
  magenta: '#8A79E0',
  cyan: '#4FD6D6',
  white: '#D7DCE4',
  brightBlack: '#5C6675',
  brightRed: '#FF8080',
  brightGreen: '#6FE38A',
  brightYellow: '#FFC65C',
  brightBlue: '#8BBEFF',
  brightMagenta: '#B0A2F0',
  brightCyan: '#83E8E8',
  brightWhite: '#FFFFFF',
} as const;

type Op =
  | { t: 'w'; d: string }
  | { t: 'r' }
  | { t: 'g'; c: number; r: number }
  | { t: 'u' };

/**
 * Streaming VT emulator backed by xterm.js inside a self-contained WebView (all
 * assets inlined in {@link XTERM_HTML}; no network). Display-only: xterm's stdin is
 * disabled and its helper textarea made readonly, so the native InputBar owns
 * input while touch scrolling and selection stay live.
 *
 * The RN → WebView bridge is `injectJavaScript` (cheapest path, bypasses React
 * reconciliation); queued writes/resets are coalesced into one injection per
 * animation frame. WebView → RN is `postMessage` for boot + fit dimensions.
 *
 * Geometry has two modes. By default the fit addon owns the grid and reports it
 * through {@link XtermTerminalViewProps.onResize}. Once the mac sends a snapshot
 * grid, {@link XtermTerminalHandle.setGrid} pins the emulator to it and
 * letterboxes — the mac is authoritative while the phone mirrors read-only, and
 * no `resize` is posted in that mode. {@link XtermTerminalHandle.releaseGrid}
 * restores fit, and is only used while a control lease is held.
 */
export const XtermTerminalView = forwardRef<XtermTerminalHandle, XtermTerminalViewProps>(
  function XtermTerminalView({ onReady, onResize, fontSize = 12, scrollback = 5000 }, ref) {
    const webRef = useRef<WebView>(null);
    const ready = useRef(false);
    const ops = useRef<Op[]>([]);
    const frame = useRef<number | undefined>(undefined);

    const flush = useCallback(() => {
      frame.current = undefined;
      if (!ready.current || ops.current.length === 0) {
        return;
      }
      const parts: string[] = [];
      let batch: string[] = [];
      const emitBatch = (): void => {
        if (batch.length > 0) {
          parts.push(`w(${JSON.stringify(batch)})`);
          batch = [];
        }
      };
      for (const op of ops.current) {
        if (op.t === 'w') {
          batch.push(op.d);
          continue;
        }
        // Everything else is ordering-sensitive against the pending writes
        // (reset → grid → snapshot), so flush the batch before emitting it.
        emitBatch();
        if (op.t === 'r') {
          parts.push('r()');
        } else if (op.t === 'g') {
          parts.push(`g(${op.c},${op.r})`);
        } else {
          parts.push('u()');
        }
      }
      emitBatch();
      ops.current = [];
      const js =
        '(function(){var z=window.__zentty;if(!z){return;}' +
        'var w=function(a){z.writeBatch(a);},r=function(){z.reset();},' +
        'g=function(c,r){z.setGrid(c,r);},u=function(){z.releaseGrid();};' +
        parts.join(';') +
        ';})();true;';
      webRef.current?.injectJavaScript(js);
    }, []);

    const schedule = useCallback(() => {
      if (frame.current === undefined) {
        frame.current = requestAnimationFrame(flush);
      }
    }, [flush]);

    useImperativeHandle(
      ref,
      () => ({
        write: (dataB64: string) => {
          ops.current.push({ t: 'w', d: dataB64 });
          schedule();
        },
        reset: () => {
          ops.current.push({ t: 'r' });
          schedule();
        },
        setGrid: (cols: number, rows: number) => {
          ops.current.push({ t: 'g', c: cols, r: rows });
          schedule();
        },
        releaseGrid: () => {
          ops.current.push({ t: 'u' });
          schedule();
        },
      }),
      [schedule],
    );

    const bootJs = useMemo(
      () =>
        `(function(){if(window.__zenttyBoot){window.__zenttyBoot(${JSON.stringify(
          XTERM_THEME,
        )},${fontSize},${scrollback});}})();true;`,
      [fontSize, scrollback],
    );

    const onMessage = useCallback(
      (event: WebViewMessageEvent) => {
        let msg: { type?: string; cols?: number; rows?: number };
        try {
          msg = JSON.parse(event.nativeEvent.data);
        } catch {
          return;
        }
        if (msg.type === 'loaded') {
          // The document has defined __zenttyBoot; boot with the resolved theme.
          webRef.current?.injectJavaScript(bootJs);
        } else if (msg.type === 'ready') {
          ready.current = true;
          onReady?.();
          flush();
        } else if (msg.type === 'resize' && typeof msg.cols === 'number' && typeof msg.rows === 'number') {
          onResize?.(msg.cols, msg.rows);
        }
      },
      [bootJs, flush, onReady, onResize],
    );

    const onLayout = useCallback((_e: LayoutChangeEvent) => {
      if (ready.current) {
        webRef.current?.injectJavaScript('window.__zentty&&window.__zentty.fit();true;');
      }
    }, []);

    return (
      <View style={styles.frame} onLayout={onLayout}>
        <WebView
          ref={webRef}
          source={{ html: XTERM_HTML }}
          originWhitelist={['*']}
          onMessage={onMessage}
          style={styles.web}
          containerStyle={styles.web}
          scrollEnabled={false}
          overScrollMode="never"
          bounces={false}
          keyboardDisplayRequiresUserAction
          hideKeyboardAccessoryView
          automaticallyAdjustContentInsets={false}
          setBuiltInZoomControls={false}
          androidLayerType="hardware"
          // Static, fully-inlined document: no navigation, no remote loads.
          allowsInlineMediaPlayback
          javaScriptEnabled
        />
      </View>
    );
  },
);

const styles = StyleSheet.create({
  frame: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#05070A',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    overflow: 'hidden',
  },
  web: {
    flex: 1,
    backgroundColor: '#05070A',
  },
});
