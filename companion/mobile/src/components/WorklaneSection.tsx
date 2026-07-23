import { StyleSheet, Text, View } from 'react-native';

import type { PaneSummary } from '@zentty/wire';

import { orderPanes, type Worklane } from '@/store';
import { colors, radius, space, type } from '@/theme';

import { PaneRow } from './PaneRow';

/** A worklane header plus its attention-ordered pane rows. */
export function WorklaneSection({
  worklane,
  onPanePress,
}: {
  worklane: Worklane;
  onPanePress: (pane: PaneSummary) => void;
}) {
  const panes = orderPanes(worklane.panes);
  return (
    <View style={styles.section}>
      <View style={styles.header}>
        <Text style={type.sectionTitle} numberOfLines={1}>
          {worklane.title}
        </Text>
        {worklane.attention ? <View style={styles.attentionDot} /> : null}
      </View>
      <View style={styles.rows}>
        {panes.map((pane) => (
          <PaneRow key={pane.paneId} pane={pane} onPress={() => onPanePress(pane)} />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  section: {
    gap: space.sm,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingHorizontal: space.xs,
  },
  attentionDot: {
    width: 7,
    height: 7,
    borderRadius: radius.pill,
    backgroundColor: colors.attention,
  },
  rows: {
    gap: space.sm,
  },
});
