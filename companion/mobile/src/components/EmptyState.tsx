import { Ionicons } from '@expo/vector-icons';
import type { ComponentProps, ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { colors, space, type } from '@/theme';

/** Centered empty/placeholder state: glyph, title, one supporting line, optional action. */
export function EmptyState({
  icon,
  title,
  message,
  action,
}: {
  icon: ComponentProps<typeof Ionicons>['name'];
  title: string;
  message: string;
  action?: ReactNode;
}) {
  return (
    <View style={styles.wrap}>
      <View style={styles.iconWrap}>
        <Ionicons name={icon} size={30} color={colors.textDim} />
      </View>
      <Text style={type.rowTitle}>{title}</Text>
      <Text style={[type.dim, styles.message]}>{message}</Text>
      {action ? <View style={styles.action}>{action}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
    padding: space.xl,
  },
  iconWrap: {
    width: 64,
    height: 64,
    borderRadius: 20,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: space.sm,
  },
  message: {
    textAlign: 'center',
    maxWidth: 300,
  },
  action: {
    marginTop: space.md,
  },
});
