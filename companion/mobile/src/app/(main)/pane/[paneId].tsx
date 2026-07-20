import { Ionicons } from '@expo/vector-icons';
import { Stack, useLocalSearchParams } from 'expo-router';
import { StyleSheet, Text, View } from 'react-native';

import { Screen, StateBadge, ToolIcon } from '@/components';
import { interactionKindLabel } from '@/lib/labels';
import { useCompanionStore } from '@/store';
import { colors, radius, space, type } from '@/theme';

/**
 * Pane detail — placeholder shell. M4 fills the body with the Terminal /
 * Conversation tabs and wires the input bar; for now it shows the pane's identity
 * and a disabled input bar so the navigation + layout are real.
 */
export default function PaneDetailScreen() {
  const { paneId, deviceId } = useLocalSearchParams<{ paneId: string; deviceId?: string }>();
  const pane = useCompanionStore((s) => {
    const view = deviceId ? s.views[deviceId] : undefined;
    for (const worklane of view?.worklanes ?? []) {
      const found = worklane.panes.find((p) => p.paneId === paneId);
      if (found) {
        return found;
      }
    }
    return undefined;
  });

  const title = pane?.title || 'Pane';
  const interaction = pane ? interactionKindLabel(pane.interactionKind) : '';

  return (
    <Screen edges={['bottom', 'left', 'right']}>
      <Stack.Screen options={{ title }} />
      <View style={styles.container}>
        <View style={styles.header}>
          <ToolIcon tool={pane?.tool} />
          <View style={styles.headerText}>
            <Text style={type.rowTitle} numberOfLines={1}>
              {title}
            </Text>
            {pane ? (
              <Text style={[type.mono, styles.dir]} numberOfLines={1}>
                {pane.workingDirectory}
              </Text>
            ) : null}
          </View>
          {pane ? <StateBadge state={pane.state} /> : null}
        </View>

        <View style={styles.body}>
          <Ionicons name="terminal-outline" size={28} color={colors.textFaint} />
          <Text style={[type.dim, styles.bodyText]}>
            {pane?.requiresHumanAttention && interaction
              ? `This pane is waiting on you (${interaction}).`
              : 'Terminal and conversation views arrive next.'}
          </Text>
        </View>

        <View style={styles.inputBar} pointerEvents="none">
          <View style={styles.input}>
            <Text style={styles.inputPlaceholder}>Message this pane…</Text>
          </View>
          <View style={styles.sendButton}>
            <Ionicons name="arrow-up" size={18} color={colors.textFaint} />
          </View>
        </View>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: space.lg,
    gap: space.lg,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  headerText: {
    flex: 1,
    gap: 2,
  },
  dir: {
    fontSize: 12,
  },
  body: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
  },
  bodyText: {
    textAlign: 'center',
    maxWidth: 280,
  },
  inputBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    opacity: 0.5,
  },
  input: {
    flex: 1,
    height: 44,
    justifyContent: 'center',
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  inputPlaceholder: {
    color: colors.textFaint,
    fontSize: 15,
  },
  sendButton: {
    width: 44,
    height: 44,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surfaceRaised,
  },
});
