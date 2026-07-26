import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, space } from '@/theme';

/**
 * A small status pill: a colored dot + label on a tinted chip. `color` drives the
 * dot and text; the chip stays a faint wash of it so the UI never turns loud.
 */
export function Pill({
  label,
  color = colors.textDim,
  dot = true,
  compact = false,
}: {
  label: string;
  color?: string;
  dot?: boolean;
  /** Tighter chip for dense spots (nav bars): smaller dot, 11pt label, snug padding. */
  compact?: boolean;
}) {
  return (
    <View style={[styles.pill, compact && styles.pillCompact]}>
      {dot && <View style={[styles.dot, compact && styles.dotCompact, { backgroundColor: color }]} />}
      <Text style={[styles.label, compact && styles.labelCompact, { color }]} numberOfLines={1}>
        {label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.xs,
    paddingVertical: 3,
    paddingHorizontal: space.sm,
    borderRadius: radius.pill,
    backgroundColor: colors.surfaceRaised,
  },
  pillCompact: {
    gap: 5,
    paddingVertical: 2,
    paddingHorizontal: space.xs + 2,
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: radius.pill,
  },
  dotCompact: {
    width: 6,
    height: 6,
  },
  label: {
    fontSize: 12,
    fontWeight: '600',
    letterSpacing: 0.2,
  },
  labelCompact: {
    fontSize: 11,
    letterSpacing: 0.1,
  },
});
