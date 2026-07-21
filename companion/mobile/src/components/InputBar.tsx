import { Ionicons } from '@expo/vector-icons';
import type { ComponentProps } from 'react';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';

import type { InputKey } from '@zentty/wire';
import { colors, radius, space } from '@/theme';

type IoniconName = ComponentProps<typeof Ionicons>['name'];

/** Special keys the toolbar can inject, in display order. */
const KEYS: { key: InputKey; label: string; icon?: IoniconName }[] = [
  { key: 'escape', label: 'Esc' },
  { key: 'tab', label: 'Tab' },
  { key: 'ctrl_c', label: '^C' },
  { key: 'up', label: '', icon: 'arrow-up' },
  { key: 'down', label: '', icon: 'arrow-down' },
  { key: 'left', label: '', icon: 'arrow-back' },
  { key: 'right', label: '', icon: 'arrow-forward' },
  { key: 'enter', label: '', icon: 'return-down-back' },
];

/**
 * The pinned input surface: a scrollable row of special-key buttons over a text
 * field. Text submits as `input.text`; each key button injects an `input.key`.
 * Disabled (dimmed, non-interactive) while the pane has no live session.
 */
export function InputBar({
  onSubmitText,
  onKey,
  disabled = false,
}: {
  onSubmitText: (text: string) => void;
  onKey: (key: InputKey) => void;
  disabled?: boolean;
}) {
  const [value, setValue] = useState('');

  const submit = useCallback(() => {
    const trimmed = value;
    if (trimmed.length === 0) {
      return;
    }
    onSubmitText(trimmed);
    setValue('');
  }, [value, onSubmitText]);

  return (
    <View style={[styles.wrap, disabled && styles.disabled]} pointerEvents={disabled ? 'none' : 'auto'}>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.keyRow}
        keyboardShouldPersistTaps="handled"
      >
        {KEYS.map(({ key, label, icon }) => (
          <Pressable
            key={key}
            onPress={() => onKey(key)}
            accessibilityRole="button"
            accessibilityLabel={`key ${key}`}
            style={({ pressed }) => [styles.keyCap, pressed && styles.keyCapPressed]}
          >
            {icon ? (
              <Ionicons name={icon} size={16} color={colors.text} />
            ) : (
              <Text style={styles.keyLabel}>{label}</Text>
            )}
          </Pressable>
        ))}
      </ScrollView>

      <View style={styles.inputRow}>
        <TextInput
          style={styles.input}
          value={value}
          onChangeText={setValue}
          placeholder="Message this pane…"
          placeholderTextColor={colors.textFaint}
          autoCapitalize="none"
          autoCorrect={false}
          returnKeyType="send"
          onSubmitEditing={submit}
          blurOnSubmit={false}
          editable={!disabled}
        />
        <Pressable
          onPress={submit}
          accessibilityRole="button"
          accessibilityLabel="send"
          style={({ pressed }) => [
            styles.send,
            value.length > 0 && styles.sendActive,
            pressed && styles.keyCapPressed,
          ]}
        >
          <Ionicons name="arrow-up" size={18} color={value.length > 0 ? '#08111F' : colors.textFaint} />
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    gap: space.sm,
    paddingTop: space.sm,
  },
  disabled: {
    opacity: 0.45,
  },
  keyRow: {
    gap: space.xs,
    paddingHorizontal: space.xs,
  },
  keyCap: {
    minWidth: 44,
    height: 34,
    paddingHorizontal: space.md,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.sm,
    backgroundColor: colors.surfaceRaised,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  keyCapPressed: {
    opacity: 0.7,
  },
  keyLabel: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '600',
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  input: {
    flex: 1,
    height: 44,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    color: colors.text,
    fontSize: 15,
  },
  send: {
    width: 44,
    height: 44,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surfaceRaised,
  },
  sendActive: {
    backgroundColor: colors.accent,
  },
});
