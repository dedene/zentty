import { Ionicons } from '@expo/vector-icons';
import { StyleSheet, View } from 'react-native';

import { toolIconName } from '@/lib/labels';
import { colors, radius } from '@/theme';

/** Square tinted tile with the tool's glyph — the leading element of a pane row. */
export function ToolIcon({ tool, color = colors.textDim }: { tool?: string; color?: string }) {
  return (
    <View style={styles.tile}>
      <Ionicons name={toolIconName(tool)} size={18} color={color} />
    </View>
  );
}

const styles = StyleSheet.create({
  tile: {
    width: 34,
    height: 34,
    borderRadius: radius.sm,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
