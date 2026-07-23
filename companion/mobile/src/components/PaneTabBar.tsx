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
    gap: space.xs,
    padding: space.xs,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  tab: {
    flex: 1,
    paddingVertical: space.sm,
    alignItems: 'center',
    borderRadius: radius.sm,
  },
  tabSelected: {
    backgroundColor: colors.surfaceRaised,
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    color: colors.textDim,
  },
  labelSelected: {
    color: colors.text,
  },
});
