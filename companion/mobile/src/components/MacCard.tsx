import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { PairedMac } from '@/core';
import { formatRelativeTime } from '@/lib/labels';
import { countAttention, type MacConnectionState } from '@/store';
import { colors, radius, space, type } from '@/theme';

import { Pill } from './Pill';

/** A paired-Mac card: name, connection state + transport, attention count, last seen. */
export function MacCard({
  mac,
  view,
  onPress,
}: {
  mac: PairedMac;
  view?: MacConnectionState;
  onPress?: () => void;
}) {
  const status = view?.status ?? 'connecting';
  const attention = view ? countAttention(view.worklanes) : 0;
  const lastSeenTs = view?.lastSnapshotAt ?? view?.lastConnectedAt;

  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [styles.card, pressed && styles.pressed]}
      accessibilityRole="button"
    >
      <View style={styles.top}>
        <View style={styles.identity}>
          <Ionicons name="desktop-outline" size={22} color={colors.textDim} />
          <Text style={type.rowTitle} numberOfLines={1}>
            {mac.macName || 'Mac'}
          </Text>
        </View>
        {attention > 0 ? (
          <Pill label={`${attention} waiting`} color={colors.attention} />
        ) : null}
      </View>

      <View style={styles.bottom}>
        <StatusPill status={status} transport={view?.transport} />
        <Text style={type.faint}>
          {status === 'connected'
            ? 'Live'
            : lastSeenTs
              ? `Seen ${formatRelativeTime(lastSeenTs)}`
              : 'Not yet connected'}
        </Text>
      </View>
    </Pressable>
  );
}

function StatusPill({
  status,
  transport,
}: {
  status: MacConnectionState['status'];
  transport?: 'direct' | 'relay';
}) {
  if (status === 'connected') {
    const via = transport === 'direct' ? 'Direct' : transport === 'relay' ? 'Relay' : 'Online';
    return <Pill label={`Online · ${via}`} color={colors.online} />;
  }
  if (status === 'connecting') {
    return <Pill label="Connecting" color={colors.accent} />;
  }
  return <Pill label="Offline" color={colors.offline} />;
}

const styles = StyleSheet.create({
  card: {
    gap: space.md,
    padding: space.lg,
    borderRadius: radius.lg,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  pressed: {
    backgroundColor: colors.surfaceRaised,
  },
  top: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
  },
  identity: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    flexShrink: 1,
  },
  bottom: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
  },
});
