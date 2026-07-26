import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { PaneSummary } from '@zentty/wire';

import { cleanPaneTitle, interactionKindLabel } from '@/lib/labels';
import { colors, space, type } from '@/theme';

import { StateBadge } from './StateBadge';
import { ToolIcon } from './ToolIcon';

/**
 * One pane row inside a {@link WorklaneSection} card: tool glyph, title + working
 * dir, and a state badge. Siblings are separated by a hairline divider (`first`
 * suppresses it on the top row) so a lane's panes read as one grouped list. Rows
 * that require human attention get an amber wash and an interaction-kind chip so
 * the "why it's waiting" reads at a glance.
 */
export function PaneRow({
  pane,
  first = false,
  onPress,
}: {
  pane: PaneSummary;
  first?: boolean;
  onPress?: () => void;
}) {
  const attention = pane.requiresHumanAttention;
  const interaction = interactionKindLabel(pane.interactionKind);

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        !first && styles.divider,
        attention && styles.attention,
        pressed && styles.pressed,
      ]}
      accessibilityRole="button"
    >
      {attention ? <View style={styles.attentionBar} /> : null}
      <ToolIcon tool={pane.tool} color={attention ? colors.attention : colors.textDim} />
      <View style={styles.body}>
        <Text style={type.rowTitle} numberOfLines={1}>
          {cleanPaneTitle(pane.title)}
        </Text>
        <View style={styles.metaRow}>
          {attention && interaction ? (
            <Text style={styles.interaction} numberOfLines={1}>
              {interaction}
            </Text>
          ) : null}
          <Text style={[type.mono, styles.dir]} numberOfLines={1}>
            {shortenPath(pane.workingDirectory)}
          </Text>
        </View>
      </View>
      <View style={styles.trailing}>
        <StateBadge state={pane.state} />
        <Ionicons name="chevron-forward" size={16} color={colors.textFaint} />
      </View>
    </Pressable>
  );
}

/** Collapse a home-relative path to `~/…/leaf` so long dirs fit one line. */
function shortenPath(path: string): string {
  const parts = path.split('/').filter(Boolean);
  if (parts.length <= 2) {
    return path;
  }
  return `…/${parts.slice(-2).join('/')}`;
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
    paddingVertical: space.md,
    paddingHorizontal: space.md,
  },
  divider: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.border,
  },
  attention: {
    backgroundColor: '#1C1A12',
  },
  // A thin amber spine on the leading edge so a waiting sibling stands out
  // within the grouped card without a full border.
  attentionBar: {
    position: 'absolute',
    left: 0,
    top: 0,
    bottom: 0,
    width: 3,
    backgroundColor: colors.attention,
  },
  pressed: {
    backgroundColor: colors.surfaceRaised,
  },
  body: {
    flex: 1,
    gap: 2,
  },
  metaRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  interaction: {
    fontSize: 12,
    fontWeight: '700',
    color: colors.attention,
  },
  dir: {
    flexShrink: 1,
    fontSize: 12,
  },
  trailing: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs,
  },
});
