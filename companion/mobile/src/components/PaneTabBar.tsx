import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { PaneTab } from '@/store';
import { colors, radius, space } from '@/theme';

const LABEL: Record<PaneTab, string> = {
  terminal: 'Terminal',
  conversation: 'Conversation',
};

/**
 * Segmented tab switcher for the pane detail screen. Only rendered when more than
 * one tab is available (i.e. the pane has a transcript), so a single-tab pane
 * shows no chrome.
 */
export function PaneTabBar({
  tabs,
  active,
  onChange,
}: {
  tabs: PaneTab[];
  active: PaneTab;
  onChange: (tab: PaneTab) => void;
}) {
  if (tabs.length < 2) {
    return null;
  }
  return (
    <View style={styles.bar}>
      {tabs.map((tab) => {
        const selected = tab === active;
        return (
          <Pressable
            key={tab}
            onPress={() => onChange(tab)}
            accessibilityRole="tab"
            accessibilityState={{ selected }}
            // Compact ~32pt track; hitSlop lifts the effective target past the
            // 44pt HIG minimum without adding vertical chrome.
            hitSlop={{ top: 8, bottom: 8 }}
            style={[styles.tab, selected && styles.tabSelected]}
          >
            <Text style={[styles.label, selected && styles.labelSelected]}>{LABEL[tab]}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    gap: 2,
    padding: 2,
    borderRadius: radius.sm,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  tab: {
    flex: 1,
    paddingVertical: space.xs + 2,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.sm - 2,
  },
  tabSelected: {
    backgroundColor: colors.surfaceRaised,
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.textDim,
  },
  labelSelected: {
    color: colors.text,
  },
});
