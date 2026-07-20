import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, RefreshControl, StyleSheet, View } from 'react-native';

import { Button, EmptyState, MacCard, Screen } from '@/components';
import { useCompanionStore } from '@/store';
import { colors, space } from '@/theme';

/**
 * Macs list: one card per paired Mac with live status, tapping into its
 * dashboard. Connects every Mac on focus and reconnects them on pull-to-refresh.
 */
export default function MacsScreen() {
  const macs = useCompanionStore((s) => s.macs);
  const views = useCompanionStore((s) => s.views);
  const connect = useCompanionStore((s) => s.connect);
  const reconnect = useCompanionStore((s) => s.reconnect);
  const [refreshing, setRefreshing] = useState(false);

  useFocusEffect(
    useCallback(() => {
      for (const mac of macs) {
        void connect(mac.macDeviceId);
      }
    }, [macs, connect]),
  );

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    for (const mac of macs) {
      void reconnect(mac.macDeviceId);
    }
    setTimeout(() => setRefreshing(false), 600);
  }, [macs, reconnect]);

  if (macs.length === 0) {
    return (
      <Screen>
        <EmptyState
          icon="qr-code-outline"
          title="No Macs paired yet"
          message="Open Zentty on your Mac, go to Settings → Mobile Devices, and scan the QR code to pair."
          action={
            <Button label="Pair a Mac" icon="add" onPress={() => router.push('/scan')} />
          }
        />
      </Screen>
    );
  }

  return (
    <Screen padded={false}>
      <FlatList
        data={macs}
        keyExtractor={(mac) => mac.macDeviceId}
        contentContainerStyle={styles.list}
        renderItem={({ item }) => (
          <MacCard
            mac={item}
            view={views[item.macDeviceId]}
            onPress={() =>
              router.push({ pathname: '/mac/[deviceId]', params: { deviceId: item.macDeviceId } })
            }
          />
        )}
        ItemSeparatorComponent={() => <View style={styles.separator} />}
        ListFooterComponent={
          <View style={styles.footer}>
            <Button
              label="Pair another Mac"
              icon="add"
              variant="secondary"
              onPress={() => router.push('/scan')}
            />
          </View>
        }
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={onRefresh}
            tintColor={colors.accent}
          />
        }
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  list: {
    padding: space.lg,
  },
  separator: {
    height: space.md,
  },
  footer: {
    marginTop: space.xl,
  },
});
