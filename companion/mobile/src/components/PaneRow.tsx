import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { PaneSummary } from '@zentty/wire';

import { interactionKindLabel } from '@/lib/labels';
import { colors, radius, space, type } from '@/theme';

import { StateBadge } from './StateBadge';
import { ToolIcon } from './ToolIcon';

/**
 * One pane row: tool glyph, title + working dir, and a state badge. Rows that
 * require human attention get an amber edge and an interaction-kind chip so the
 * "why it's waiting" reads at a glance.
 */
export function PaneRow({ pane, onPress }: { pane: PaneSummary; onPress?: () => void }) {
  const attention = pane.requiresHumanAttention;
  const interaction = interactionKindLabel(pane.interactionKind);

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        attention && styles.attention,
        pressed && styles.pressed,
      ]}
      accessibilityRole="button"
    >
      <ToolIcon tool={pane.tool} color={attention ? colors.attention : colors.textDim} />
      <View style={styles.body}>
        <Text style={type.rowTitle} numberOfLines={1}>
          {pane.title}
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
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  attention: {
    borderColor: colors.attention,
    backgroundColor: '#1C1A12',
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
