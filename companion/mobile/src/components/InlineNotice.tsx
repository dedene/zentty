import { Ionicons } from '@expo/vector-icons';
import type { ComponentProps, ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, space, type } from '@/theme';

type Tone = 'error' | 'warning' | 'info';

const TONE: Record<Tone, { color: string; bg: string; icon: ComponentProps<typeof Ionicons>['name'] }> = {
  error: { color: colors.stopped, bg: '#1E1414', icon: 'alert-circle-outline' },
  warning: { color: colors.attention, bg: '#1C1A12', icon: 'time-outline' },
  info: { color: colors.accent, bg: '#101722', icon: 'information-circle-outline' },
};

/**
 * A calm inline status card for pairing/camera failures — the alternative to
 * stacked `Alert.alert` modals. One icon, a title, a supporting line, and an
 * optional action slot.
 */
export function InlineNotice({
  tone,
  title,
  message,
  children,
}: {
  tone: Tone;
  title: string;
  message: string;
  children?: ReactNode;
}) {
  const t = TONE[tone];
  return (
    <View style={[styles.card, { backgroundColor: t.bg, borderColor: t.color }]}>
      <View style={styles.head}>
        <Ionicons name={t.icon} size={20} color={t.color} />
        <Text style={[type.rowTitle, { color: t.color }]}>{title}</Text>
      </View>
      <Text style={type.dim}>{message}</Text>
      {children ? <View style={styles.actions}>{children}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    gap: space.sm,
    padding: space.lg,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
  },
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  actions: {
    marginTop: space.sm,
    gap: space.sm,
  },
});
