import { Ionicons } from '@expo/vector-icons';
import { StyleSheet, Text, View } from 'react-native';

import { formatRelativeTime } from '@/lib/labels';
import { colors, radius, space } from '@/theme';

/**
 * Shown above a dashboard when it is disconnected but still displaying cached
 * state. Explains that the data is last-known and when it was captured.
 */
export function StaleBanner({ lastSnapshotAt }: { lastSnapshotAt?: number }) {
  return (
    <View style={styles.banner}>
      <Ionicons name="cloud-offline-outline" size={16} color={colors.attention} />
      <Text style={styles.text}>
        Disconnected — showing last-known state
        {lastSnapshotAt ? ` from ${formatRelativeTime(lastSnapshotAt)}` : ''}.
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    backgroundColor: '#1C1A12',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.attention,
  },
  text: {
    flex: 1,
    fontSize: 13,
    color: colors.text,
  },
});
