import { Stack, router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useMemo, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, View } from 'react-native';

import { EmptyState, Screen, StaleBanner, WorklaneSection } from '@/components';
import { isStale, orderWorklanes, useCompanionStore } from '@/store';
import { colors, space } from '@/theme';

/**
 * Dashboard for one Mac: worklane sections with attention-ordered pane rows, live
 * from the session's snapshot + deltas, with a stale banner over cached state when
 * disconnected. Tapping a pane opens its detail screen.
 */
export default function DashboardScreen() {
  const { deviceId } = useLocalSearchParams<{ deviceId: string }>();
  const mac = useCompanionStore((s) => s.macs.find((m) => m.macDeviceId === deviceId));
  const view = useCompanionStore((s) => s.views[deviceId]);
  const connect = useCompanionStore((s) => s.connect);
  const reconnect = useCompanionStore((s) => s.reconnect);
  const [refreshing, setRefreshing] = useState(false);

  useFocusEffect(
    useCallback(() => {
      void connect(deviceId);
    }, [deviceId, connect]),
  );

  const worklanes = useMemo(() => orderWorklanes(view?.worklanes ?? []), [view?.worklanes]);
  const status = view?.status ?? 'connecting';
  const stale = isStale(status, (view?.worklanes.length ?? 0) > 0);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    void reconnect(deviceId);
    setTimeout(() => setRefreshing(false), 600);
  }, [deviceId, reconnect]);

  const openPane = useCallback(
    (paneId: string) => {
      router.push({ pathname: '/pane/[paneId]', params: { paneId, deviceId } });
    },
    [deviceId],
  );

  return (
    <Screen padded={false}>
      <Stack.Screen options={{ title: mac?.macName || 'Dashboard' }} />
      {worklanes.length === 0 ? (
        <EmptyState
          icon={status === 'offline' ? 'cloud-offline-outline' : 'pulse-outline'}
          title={status === 'offline' ? 'Mac offline' : status === 'connected' ? 'No active agents' : 'Connecting…'}
          message={
            status === 'offline'
              ? 'Your Mac is unreachable right now. This view will refresh when it comes back.'
              : status === 'connected'
                ? 'No agents are running on this Mac. Start one in Zentty and it will appear here.'
                : 'Reaching your Mac over the fastest available transport.'
          }
        />
      ) : (
        <FlatList
          data={worklanes}
          keyExtractor={(w) => w.id}
          contentContainerStyle={styles.list}
          ListHeaderComponent={
            stale ? (
              <View style={styles.banner}>
                <StaleBanner lastSnapshotAt={view?.lastSnapshotAt} />
              </View>
            ) : null
          }
          renderItem={({ item }) => (
            <WorklaneSection worklane={item} onPanePress={(pane) => openPane(pane.paneId)} />
          )}
          ItemSeparatorComponent={() => <View style={styles.separator} />}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.accent} />
          }
        />
      )}
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: {
    padding: space.lg,
  },
  banner: {
    marginBottom: space.lg,
  },
  separator: {
    height: space.xl,
  },
});
