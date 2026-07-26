import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { colors, space } from '@/theme';

/**
 * Full-bleed dark screen container with safe-area insets. `edges` lets a screen
 * opt out of the top inset when it sits under a native header.
 */
export function Screen({
  children,
  edges = ['top', 'bottom'],
  padded = true,
}: {
  children: ReactNode;
  edges?: ('top' | 'bottom' | 'left' | 'right')[];
  padded?: boolean;
}) {
  return (
    <SafeAreaView style={styles.safe} edges={edges}>
      <View style={[styles.inner, padded && styles.padded]}>{children}</View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: colors.bg,
  },
  inner: {
    flex: 1,
  },
  padded: {
    paddingHorizontal: space.lg,
  },
});
