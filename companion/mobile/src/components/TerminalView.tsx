import { useCallback, useRef } from 'react';
import {
  ActivityIndicator,
  type LayoutChangeEvent,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { PaneTextState } from '@/store';
import { TERMINAL_CELL_WIDTH, TERMINAL_FONT_SIZE, TERMINAL_LINE_HEIGHT } from '@/lib/cellMetrics';
import { colors, mono, space } from '@/theme';

/** Distance from the bottom (px) within which we keep auto-scrolling to the tail. */
const STICK_THRESHOLD = 48;

/**
 * Read-only monospace mirror of a pane's terminal. Renders the fetched scrollback
 * (if any) above the live viewport at a fixed grid cell, scrolls horizontally for
 * lines wider than the screen, auto-follows the tail, and fires `onPullTop` when
 * the user drags to the very top so the screen can fetch more scrollback.
 */
export function TerminalView({
  text,
  scrollbackLoading,
  onPullTop,
  onMeasure,
}: {
  text?: PaneTextState;
  scrollbackLoading?: boolean;
  onPullTop?: () => void;
  onMeasure?: (widthPx: number, heightPx: number) => void;
}) {
  const scrollRef = useRef<ScrollView>(null);
  const stickToBottom = useRef(true);
  const pulledTop = useRef(false);

  const content = text
    ? (text.scrollback ? `${text.scrollback}\n` : '') + text.viewport
    : '';
  const lineWidth = Math.max(text?.gridCols ?? 1, 1) * TERMINAL_CELL_WIDTH + space.lg * 2;

  const onLayout = useCallback(
    (event: LayoutChangeEvent) => {
      const { width, height } = event.nativeEvent.layout;
      onMeasure?.(width, height);
    },
    [onMeasure],
  );

  const onContentSizeChange = useCallback(() => {
    if (stickToBottom.current) {
      scrollRef.current?.scrollToEnd({ animated: false });
    }
  }, []);

  const onScroll = useCallback(
    (event: NativeSyntheticEvent<NativeScrollEvent>) => {
      const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
      const distanceFromBottom = contentSize.height - layoutMeasurement.height - contentOffset.y;
      stickToBottom.current = distanceFromBottom <= STICK_THRESHOLD;

      if (contentOffset.y <= 0) {
        if (!pulledTop.current) {
          pulledTop.current = true;
          onPullTop?.();
        }
      } else {
        pulledTop.current = false;
      }
    },
    [onPullTop],
  );

  return (
    <View style={styles.frame} onLayout={onLayout}>
      {scrollbackLoading ? (
        <View style={styles.loadingBar}>
          <ActivityIndicator size="small" color={colors.textFaint} />
          <Text style={styles.loadingText}>Loading scrollback…</Text>
        </View>
      ) : null}
      <ScrollView
        ref={scrollRef}
        style={styles.vertical}
        onScroll={onScroll}
        scrollEventThrottle={16}
        onContentSizeChange={onContentSizeChange}
        showsVerticalScrollIndicator
      >
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator
          contentContainerStyle={styles.horizontalContent}
        >
          <Text
            style={[styles.text, { width: lineWidth }]}
            selectable
            allowFontScaling={false}
          >
            {content || ' '}
          </Text>
        </ScrollView>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  frame: {
    flex: 1,
    borderRadius: 12,
    backgroundColor: '#05070A',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    overflow: 'hidden',
  },
  loadingBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingVertical: space.xs,
    paddingHorizontal: space.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  loadingText: {
    color: colors.textFaint,
    fontSize: 12,
  },
  vertical: {
    flex: 1,
  },
  horizontalContent: {
    padding: space.lg,
  },
  text: {
    fontFamily: mono,
    fontSize: TERMINAL_FONT_SIZE,
    lineHeight: TERMINAL_LINE_HEIGHT,
    color: '#D7DCE4',
  },
});
