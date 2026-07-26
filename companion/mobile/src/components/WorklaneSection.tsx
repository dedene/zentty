import { StyleSheet, Text, View } from 'react-native';

import type { PaneSummary } from '@zentty/wire';

import { type Worklane } from '@/store';
import { colors, radius, space, type } from '@/theme';

import { PaneRow } from './PaneRow';

/**
 * One worklane, rendered as a single titled card — mirroring the Mac sidebar,
 * where a lane is a labeled group with its panes stacked beneath it. The header
 * carries the worklane title (the same label the desktop sidebar shows), a subtle
 * pane count, and an attention dot when any contained pane is waiting. The panes
 * live inside the same card, divided by hairlines, so siblings read as siblings
 * instead of as loose, unrelated cards.
 */
export function WorklaneSection({
  worklane,
  onPanePress,
}: {
  worklane: Worklane;
  onPanePress: (pane: PaneSummary) => void;
}) {
  // Render panes in the exact order the Mac sidebar shows them — the wire
  // array carries workspace order; attention is conveyed by row styling.
  const panes = worklane.panes;
  // The Mac only sends a title the user explicitly set; untitled lanes get no
  // header label — the card border alone carries the grouping.
  const title = worklane.title.trim();
  return (
    <View style={[styles.card, worklane.attention && styles.cardAttention]}>
      {title ? (
        <View style={styles.header}>
          <Text
            style={[type.sectionTitle, worklane.attention && styles.titleAttention]}
            numberOfLines={1}
          >
            {title}
          </Text>
          <View style={styles.headerMeta}>
            <Text style={styles.count}>{panes.length}</Text>
            {worklane.attention ? <View style={styles.attentionDot} /> : null}
          </View>
        </View>
      ) : null}
      <View>
        {panes.map((pane, index) => (
          <PaneRow
            key={pane.paneId}
            pane={pane}
            first={index === 0}
            onPress={() => onPanePress(pane)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    // Clip the pane rows' pressed/attention fills to the card's rounded corners.
    overflow: 'hidden',
  },
  cardAttention: {
    borderColor: colors.attention,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    backgroundColor: colors.surfaceRaised,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  titleAttention: {
    color: colors.attention,
  },
  headerMeta: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  count: {
    fontSize: 12,
    fontWeight: '600',
    color: colors.textFaint,
    fontVariant: ['tabular-nums'],
  },
  attentionDot: {
    width: 7,
    height: 7,
    borderRadius: radius.pill,
    backgroundColor: colors.attention,
  },
});
