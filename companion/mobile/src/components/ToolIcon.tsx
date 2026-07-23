import { Ionicons } from '@expo/vector-icons';
import { StyleSheet, View } from 'react-native';
import { SvgXml } from 'react-native-svg';

import { agentIconSvg, toolIconName } from '@/lib/labels';
import { colors, radius } from '@/theme';

/**
 * Square tinted tile with the tool's logo — the leading element of a pane row
 * and the pane detail header. Renders the desktop app's per-agent SVG when the
 * tool is recognized (tinted to a single color, matching the desktop's
 * monochrome-template treatment); unknown tools fall back to a terminal glyph.
 */
export function ToolIcon({ tool, color = colors.textDim }: { tool?: string; color?: string }) {
  const svg = agentIconSvg(tool);
  return (
    <View style={styles.tile}>
      {svg ? (
        <SvgXml xml={svg} width={18} height={18} color={color} />
      ) : (
        <Ionicons name={toolIconName(tool)} size={18} color={color} />
      )}
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
