import { Ionicons } from '@expo/vector-icons';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import type { LeaseRevokedReason } from '@zentty/wire';
import type { LeaseSnapshot } from '@/store';
import { Button } from './Button';
import { colors, radius, space, type } from '@/theme';

const REVOKED_REASON: Record<LeaseRevokedReason, string> = {
  takeback: 'The Mac took back control.',
  expired: 'Control expired — the connection went quiet.',
  pane_closed: 'The pane was closed on the Mac.',
  superseded: 'Another device took control.',
};

/**
 * Takeover affordance for the Terminal tab (spec §2.6). Reflects the lease state:
 * offer "Take control" when idle, show the held grid with a Release button, or
 * explain why control dropped to a read-only mirror.
 *
 * `demoted` collapses only the idle state to a quiet inline link — used on agent
 * panes that also have a Conversation tab, where take-control is a power-user
 * escape hatch rather than the main path. Every active lease state stays a full
 * card regardless, since a held lease is reflowing the Mac and the Release
 * control must stay visible.
 */
export function TakeoverControls({
  lease,
  grid,
  demoted = false,
  onTakeControl,
  onRelease,
}: {
  lease: LeaseSnapshot;
  grid?: { cols: number; rows: number };
  demoted?: boolean;
  onTakeControl: () => void;
  onRelease: () => void;
}) {
  if (lease.status === 'requesting') {
    return (
      <View style={[styles.card, styles.rowCard]}>
        <ActivityIndicator size="small" color={colors.accent} />
        <Text style={type.dim}>Requesting control…</Text>
      </View>
    );
  }

  if (lease.status === 'held') {
    const effective = lease.effective;
    const clamped =
      effective && lease.client
        ? effective.cols !== lease.client.cols || effective.rows !== lease.client.rows
        : false;
    return (
      <View style={[styles.card, styles.heldCard]}>
        <View style={styles.heldHead}>
          <Ionicons name="phone-portrait-outline" size={18} color={colors.accent} />
          <Text style={styles.heldTitle}>
            In control{effective ? ` · ${effective.cols}×${effective.rows}` : ''}
          </Text>
        </View>
        <Text style={type.faint}>
          {clamped
            ? 'The Mac clamped the grid to fit its limits.'
            : 'The pane is reflowed to your phone. The Mac shows a placeholder.'}
        </Text>
        <Button label="Release control" variant="secondary" icon="close" onPress={onRelease} />
      </View>
    );
  }

  if (lease.status === 'readonly') {
    return (
      <View style={[styles.card, styles.readonlyCard]}>
        <View style={styles.heldHead}>
          <Ionicons name="lock-closed-outline" size={16} color={colors.attention} />
          <Text style={styles.readonlyTitle}>Read-only mirror</Text>
        </View>
        <Text style={type.faint}>
          {lease.revokedReason ? REVOKED_REASON[lease.revokedReason] : 'Control ended.'}
        </Text>
        <Button label="Take control again" variant="secondary" icon="refresh" onPress={onTakeControl} />
      </View>
    );
  }

  // idle, demoted: a quiet inline link (agent panes with a Conversation tab).
  if (demoted) {
    return (
      <Pressable
        onPress={onTakeControl}
        style={styles.demotedLink}
        hitSlop={8}
        accessibilityRole="button"
        accessibilityLabel="Take control and reflow the pane to your phone"
      >
        <Ionicons name="phone-portrait-outline" size={14} color={colors.textDim} />
        <Text style={type.dim}>Take control</Text>
        {lease.error ? <Text style={type.faint}>· {lease.error}</Text> : null}
      </Pressable>
    );
  }

  // idle, primary: the full card (panes whose only surface is the terminal).
  return (
    <View style={[styles.card, styles.rowCard]}>
      <View style={styles.idleText}>
        <Text style={type.dim}>Take control</Text>
        <Text style={type.faint}>
          {grid ? `Reflow to ${grid.cols}×${grid.rows} for your phone` : 'Reflow the pane to your phone'}
          {lease.error ? ` · ${lease.error}` : ''}
        </Text>
      </View>
      <Button label="Take control" icon="phone-portrait-outline" onPress={onTakeControl} />
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    padding: space.md,
  },
  rowCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.md,
  },
  idleText: {
    flex: 1,
    gap: 2,
  },
  demotedLink: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-end',
    gap: space.xs,
    paddingVertical: space.xs,
    paddingHorizontal: space.sm,
  },
  heldCard: {
    gap: space.sm,
    borderColor: colors.accentDim,
    backgroundColor: '#0E1622',
  },
  readonlyCard: {
    gap: space.sm,
    borderColor: '#3A3320',
    backgroundColor: '#171410',
  },
  heldHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  heldTitle: {
    color: colors.text,
    fontSize: 15,
    fontWeight: '600',
  },
  readonlyTitle: {
    color: colors.attention,
    fontSize: 14,
    fontWeight: '600',
  },
});
