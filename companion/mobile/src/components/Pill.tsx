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
}: {
  label: string;
  color?: string;
  dot?: boolean;
}) {
  return (
    <View style={styles.pill}>
      {dot && <View style={[styles.dot, { backgroundColor: color }]} />}
      <Text style={[styles.label, { color }]} numberOfLines={1}>
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
  dot: {
    width: 7,
    height: 7,
    borderRadius: radius.pill,
  },
  label: {
    fontSize: 12,
    fontWeight: '600',
    letterSpacing: 0.2,
  },
});
