import { Ionicons } from '@expo/vector-icons';
import { useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Button, EmptyState, Screen } from '@/components';
import type { PairedMac } from '@/core';
import { APP_VERSION } from '@/runtime/device';
import { useCompanionStore } from '@/store';
import { colors, radius, space, type } from '@/theme';

/**
 * Settings sheet: manage paired Macs (unpair, view relay URL) and see the app
 * version. Presented modally from the Macs list header.
 */
export default function SettingsScreen() {
  const macs = useCompanionStore((s) => s.macs);
  const unpair = useCompanionStore((s) => s.unpair);

  return (
    <Screen>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={[type.sectionTitle, styles.heading]}>Paired Macs</Text>
        {macs.length === 0 ? (
          <EmptyState
            icon="desktop-outline"
            title="No paired Macs"
            message="Pair a Mac from the Macs list to manage it here."
          />
        ) : (
          <View style={styles.list}>
            {macs.map((mac) => (
              <MacSettingsRow
                key={mac.macDeviceId}
                mac={mac}
                onUnpair={() => void unpair(mac.macDeviceId)}
              />
            ))}
          </View>
        )}

        <Text style={[type.sectionTitle, styles.heading]}>About</Text>
        <View style={styles.aboutRow}>
          <Text style={type.body}>Version</Text>
          <Text style={type.dim}>{APP_VERSION}</Text>
        </View>
      </ScrollView>
    </Screen>
  );
}

function MacSettingsRow({ mac, onUnpair }: { mac: PairedMac; onUnpair: () => void }) {
  const [confirming, setConfirming] = useState(false);

  return (
    <View style={styles.card}>
      <View style={styles.cardHead}>
        <Ionicons name="desktop-outline" size={20} color={colors.textDim} />
        <Text style={type.rowTitle} numberOfLines={1}>
          {mac.macName || 'Mac'}
        </Text>
      </View>

      <Field label="Relay" value={mac.relayUrl ?? 'Not configured'} />
      {mac.lanHint ? (
        <Field label="Direct" value={`${mac.lanHint.host}:${mac.lanHint.port}`} />
      ) : null}
      <Field label="Device ID" value={truncateId(mac.macDeviceId)} />

      <View style={styles.action}>
        {confirming ? (
          <View style={styles.confirmRow}>
            <View style={styles.confirmFlex}>
              <Button label="Unpair" icon="trash-outline" variant="danger" onPress={onUnpair} />
            </View>
            <View style={styles.confirmFlex}>
              <Button label="Cancel" variant="secondary" onPress={() => setConfirming(false)} />
            </View>
          </View>
        ) : (
          <Button
            label="Unpair this Mac"
            icon="trash-outline"
            variant="secondary"
            onPress={() => setConfirming(true)}
          />
        )}
      </View>
    </View>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.field}>
      <Text style={type.faint}>{label}</Text>
      <Text style={[type.mono, styles.fieldValue]} numberOfLines={1}>
        {value}
      </Text>
    </View>
  );
}

/** base64url device ids are long; show head…tail so the row stays one line. */
function truncateId(id: string): string {
  return id.length > 16 ? `${id.slice(0, 8)}…${id.slice(-6)}` : id;
}

const styles = StyleSheet.create({
  content: {
    padding: space.lg,
    gap: space.md,
  },
  heading: {
    marginTop: space.sm,
  },
  list: {
    gap: space.md,
  },
  card: {
    gap: space.sm,
    padding: space.lg,
    borderRadius: radius.lg,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  cardHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    marginBottom: space.xs,
  },
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.md,
  },
  fieldValue: {
    flexShrink: 1,
    fontSize: 12,
  },
  action: {
    marginTop: space.sm,
  },
  confirmRow: {
    flexDirection: 'row',
    gap: space.sm,
  },
  confirmFlex: {
    flex: 1,
  },
  aboutRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: space.lg,
    paddingVertical: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
});
