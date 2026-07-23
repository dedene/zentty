import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { QuickAction, QuickActionTone } from '@/lib/quickActions';
import { colors, radius, space } from '@/theme';

const TONE: Record<QuickActionTone, { bg: string; fg: string; border: string }> = {
  approve: { bg: colors.accent, fg: '#08111F', border: colors.accent },
  deny: { bg: 'transparent', fg: colors.danger, border: colors.danger },
  neutral: { bg: colors.surfaceRaised, fg: colors.text, border: colors.border },
};

/**
 * The structured approve / deny / option bar, pinned above the input in both
 * tabs. Each button sends its `input.quickAction` actionId. Rendered only when
 * the pane is waiting on a human for an interactive kind.
 */
export function QuickActionsBar({
  actions,
  onAction,
}: {
  actions: QuickAction[];
  onAction: (actionId: string) => void;
}) {
  if (actions.length === 0) {
    return null;
  }
  return (
    <View style={styles.bar}>
      {actions.map((action) => {
        const tone = TONE[action.tone];
        return (
          <Pressable
            key={action.id}
            onPress={() => onAction(action.id)}
            accessibilityRole="button"
            style={({ pressed }) => [
              styles.button,
              { backgroundColor: tone.bg, borderColor: tone.border },
              action.tone === 'neutral' && styles.optionButton,
              pressed && styles.pressed,
            ]}
          >
            <Text style={[styles.label, { color: tone.fg }]}>{action.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: space.sm,
  },
  button: {
    flexGrow: 1,
    flexBasis: 0,
    minWidth: 72,
    paddingVertical: space.md,
    paddingHorizontal: space.lg,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: 'center',
  },
  optionButton: {
    flexGrow: 0,
    flexBasis: 'auto',
    minWidth: 48,
    paddingHorizontal: space.md,
  },
  pressed: {
    opacity: 0.8,
  },
  label: {
    fontSize: 15,
    fontWeight: '600',
  },
});
