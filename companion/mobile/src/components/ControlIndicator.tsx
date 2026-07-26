import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { LeaseRevokedReason } from '@zentty/wire';
import type { LeaseSnapshot } from '@/store';
import { colors, space, type } from '@/theme';

const REVOKED_REASON: Record<LeaseRevokedReason, string> = {
  takeback: 'the Mac took back control',
  expired: 'the connection went quiet',
  pane_closed: 'the pane was closed',
  superseded: 'another device took control',
};

/**
 * Minimal implicit-control affordance for the pane screen. Control is acquired on
 * entering the pane and released on leaving, so there is no button — this is a
 * single slim line near the input strip that says whether keystrokes reach the
 * Mac ("Controlling") or not ("View only"), and why. When control was denied or
 * lost the whole line becomes a subtle tap-to-retry.
 */
export function ControlIndicator({ lease, onRetry }: { lease: LeaseSnapshot; onRetry: () => void }) {
  if (lease.status === 'held') {
    const g = lease.effective;
    return (
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: colors.online }]} />
        <Text style={type.dim}>Controlling{g ? ` · ${g.cols}×${g.rows}` : ''}</Text>
      </View>
    );
  }

  if (lease.status === 'requesting') {
    return (
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: colors.textFaint }]} />
        <Text style={type.dim}>Taking control…</Text>
      </View>
    );
  }

  // readonly (lost) or idle+error (denied): view-only, retryable. A plain idle
  // (control not yet wanted) shows the quiet view-only line without a retry.
  const reason =
    lease.status === 'readonly' && lease.revokedReason
      ? REVOKED_REASON[lease.revokedReason]
      : lease.error;
  const retryable = lease.status === 'readonly' || lease.error !== undefined;

  const content = (
    <View style={styles.row}>
      <View style={[styles.dot, { backgroundColor: colors.attention }]} />
      <Text style={type.dim}>View only</Text>
      {reason ? (
        <Text style={type.faint} numberOfLines={1}>
          · {reason}
        </Text>
      ) : null}
      {retryable ? <Text style={styles.retry}>Tap to retry</Text> : null}
    </View>
  );

  if (!retryable) {
    return content;
  }
  return (
    <Pressable
      onPress={onRetry}
      hitSlop={8}
      accessibilityRole="button"
      accessibilityLabel="Retry taking control of this pane"
    >
      {content}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingHorizontal: space.xs,
    minHeight: 20,
  },
  dot: {
    width: 7,
    height: 7,
    borderRadius: 4,
  },
  retry: {
    marginLeft: 'auto',
    fontSize: 12,
    fontWeight: '600',
    color: colors.accent,
  },
});
