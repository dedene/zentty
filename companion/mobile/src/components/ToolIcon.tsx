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
export function ToolIcon({
  tool,
  color = colors.textDim,
  size = 34,
}: {
  tool?: string;
  color?: string;
  /** Tile edge length; the glyph scales with it. Defaults to the row/list size. */
  size?: number;
}) {
  const svg = agentIconSvg(tool);
  const glyph = Math.round(size * 0.53);
  return (
    <View style={[styles.tile, { width: size, height: size }]}>
      {svg ? (
        <SvgXml xml={svg} width={glyph} height={glyph} color={color} />
      ) : (
        <Ionicons name={toolIconName(tool)} size={glyph} color={color} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  tile: {
    borderRadius: radius.sm,
    backgroundColor: colors.surfaceRaised,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
