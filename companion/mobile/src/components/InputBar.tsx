import { Ionicons } from '@expo/vector-icons';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActionSheetIOS,
  Keyboard,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import type { InputKey } from '@zentty/wire';
import { colors, mono, radius, space } from '@/theme';

/**
 * The pinned input surface for a pane: a compact accessory rail over the text
 * field. The rail groups related keys into capsule clusters (scrollable), with
 * a keyboard-dismiss button and a hold-to-repeat D-pad pinned on the right so
 * arrows stay reachable regardless of scroll position.
 *
 * Text submits as `input.text`; key buttons inject `input.key`; symbol keys
 * pass through as raw `input.text` bytes (the Mac injects them into the pty
 * verbatim, no newline). Disabled (dimmed, non-interactive) while the pane has
 * no live session.
 */

/** Control-key variants the ctrl segment can send; tap sends the current one,
 * long-press picks another. Wire-limited to this set (`InputKey`). */
const CTRL_VARIANTS: { key: InputKey; label: string }[] = [
  { key: 'ctrl_c', label: '^C' },
  { key: 'ctrl_d', label: '^D' },
  { key: 'ctrl_z', label: '^Z' },
  { key: 'ctrl_r', label: '^R' },
];

/** Symbols that are tedious on the system keyboard; sent as raw pty bytes. */
const SYMBOLS = ['~', '|', '/', '-'] as const;

const DPAD_SIZE = 52;
const DPAD_DEAD_ZONE = 9;
/** Vertical repeats slower than horizontal: line jumps read faster than column moves. */
const REPEAT_MS_VERTICAL = 105;
const REPEAT_MS_HORIZONTAL = 80;

type Direction = 'up' | 'down' | 'left' | 'right';

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
  const [ctrlVariant, setCtrlVariant] = useState(0);

  const submit = useCallback(() => {
    if (value.length === 0) {
      return;
    }
    onSubmitText(value);
    setValue('');
  }, [value, onSubmitText]);

  const pickCtrlVariant = useCallback(() => {
    if (Platform.OS === 'ios') {
      ActionSheetIOS.showActionSheetWithOptions(
        {
          options: [...CTRL_VARIANTS.map((v) => `Send ${v.label}`), 'Cancel'],
          cancelButtonIndex: CTRL_VARIANTS.length,
        },
        (index) => {
          if (index < CTRL_VARIANTS.length) {
            setCtrlVariant(index);
            onKey(CTRL_VARIANTS[index].key);
          }
        },
      );
    } else {
      setCtrlVariant((current) => (current + 1) % CTRL_VARIANTS.length);
    }
  }, [onKey]);

  return (
    <View style={[styles.wrap, disabled && styles.disabled]} pointerEvents={disabled ? 'none' : 'auto'}>
      <View style={styles.rail}>
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={styles.clusterRow}
          keyboardShouldPersistTaps="handled"
        >
          <View style={styles.cluster}>
            <KeySegment label="esc" onPress={() => onKey('escape')} />
            <Divider />
            <KeySegment
              label={CTRL_VARIANTS[ctrlVariant].label}
              hint
              onPress={() => onKey(CTRL_VARIANTS[ctrlVariant].key)}
              onLongPress={pickCtrlVariant}
              accessibilityLabel={`${CTRL_VARIANTS[ctrlVariant].label} control key`}
              accessibilityHint="Long-press to choose a different control key"
            />
            <Divider />
            <KeySegment label="tab" onPress={() => onKey('tab')} />
            <Divider />
            <KeySegment icon="return-down-back" accessibilityLabel="return" onPress={() => onKey('enter')} />
          </View>

          <View style={styles.cluster}>
            {SYMBOLS.map((symbol, index) => (
              <View key={symbol} style={styles.symbolPair}>
                {index > 0 ? <Divider /> : null}
                <KeySegment label={symbol} narrow onPress={() => onSubmitText(symbol)} />
              </View>
            ))}
          </View>
        </ScrollView>

        <View style={styles.fixedControls}>
          <Pressable
            onPress={Keyboard.dismiss}
            accessibilityRole="button"
            accessibilityLabel="Dismiss keyboard"
            style={({ pressed }) => [styles.circleButton, pressed && styles.pressed]}
          >
            <Ionicons name="chevron-down" size={16} color={colors.text} />
          </Pressable>
          <DPad onDirection={(direction) => onKey(direction)} />
        </View>
      </View>

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
            pressed && styles.pressed,
          ]}
        >
          <Ionicons name="arrow-up" size={18} color={value.length > 0 ? '#08111F' : colors.textFaint} />
        </Pressable>
      </View>
    </View>
  );
}

function Divider() {
  return <View style={styles.divider} />;
}

function KeySegment({
  label,
  icon,
  hint = false,
  narrow = false,
  onPress,
  onLongPress,
  accessibilityLabel,
  accessibilityHint,
}: {
  label?: string;
  icon?: 'return-down-back';
  hint?: boolean;
  narrow?: boolean;
  onPress: () => void;
  onLongPress?: () => void;
  accessibilityLabel?: string;
  accessibilityHint?: string;
}) {
  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityHint={accessibilityHint}
      hitSlop={{ top: 8, bottom: 8 }}
      style={({ pressed }) => [styles.segment, narrow && styles.segmentNarrow, pressed && styles.pressed]}
    >
      {icon ? (
        <Ionicons name={icon} size={15} color={colors.text} />
      ) : (
        <View style={styles.segmentLabelRow}>
          <Text style={styles.segmentLabel}>{label}</Text>
          {hint ? <Ionicons name="chevron-expand" size={9} color={colors.textFaint} /> : null}
        </View>
      )}
    </Pressable>
  );
}

/**
 * Circular four-way pad pinned to the rail's right edge. Press a quadrant to
 * send that arrow once; keep holding (or drag toward a direction) to repeat.
 * Repeat cadence differs per axis so vertical history scrubbing stays readable.
 */
function DPad({ onDirection }: { onDirection: (direction: Direction) => void }) {
  const [active, setActive] = useState<Direction | null>(null);
  const repeatTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const onDirectionRef = useRef(onDirection);
  onDirectionRef.current = onDirection;

  const stopRepeat = useCallback(() => {
    if (repeatTimer.current) {
      clearInterval(repeatTimer.current);
      repeatTimer.current = null;
    }
    setActive(null);
  }, []);

  useEffect(() => stopRepeat, [stopRepeat]);

  const startRepeat = useCallback(
    (direction: Direction) => {
      if (repeatTimer.current) {
        clearInterval(repeatTimer.current);
      }
      setActive(direction);
      onDirectionRef.current(direction);
      const interval = direction === 'up' || direction === 'down' ? REPEAT_MS_VERTICAL : REPEAT_MS_HORIZONTAL;
      repeatTimer.current = setInterval(() => onDirectionRef.current(direction), interval);
    },
    [],
  );

  const directionForOffset = useCallback((dx: number, dy: number): Direction | null => {
    if (Math.hypot(dx, dy) < DPAD_DEAD_ZONE) {
      return null;
    }
    if (Math.abs(dx) > Math.abs(dy)) {
      return dx > 0 ? 'right' : 'left';
    }
    return dy > 0 ? 'down' : 'up';
  }, []);

  const handleTouch = useCallback(
    (locationX: number, locationY: number) => {
      const direction = directionForOffset(locationX - DPAD_SIZE / 2, locationY - DPAD_SIZE / 2);
      if (direction === null) {
        return;
      }
      if (direction !== active) {
        startRepeat(direction);
      }
    },
    [active, directionForOffset, startRepeat],
  );

  return (
    <View
      style={styles.dpad}
      accessible
      accessibilityRole="adjustable"
      accessibilityLabel="Arrow keys"
      accessibilityHint="Press an edge to send that arrow key; hold to repeat"
      onStartShouldSetResponder={() => true}
      onMoveShouldSetResponder={() => true}
      onResponderGrant={(event) => handleTouch(event.nativeEvent.locationX, event.nativeEvent.locationY)}
      onResponderMove={(event) => handleTouch(event.nativeEvent.locationX, event.nativeEvent.locationY)}
      onResponderRelease={stopRepeat}
      onResponderTerminate={stopRepeat}
    >
      <Ionicons
        name="chevron-up"
        size={13}
        color={active === 'up' ? colors.accent : colors.text}
        style={styles.dpadUp}
      />
      <Ionicons
        name="chevron-down"
        size={13}
        color={active === 'down' ? colors.accent : colors.text}
        style={styles.dpadDown}
      />
      <Ionicons
        name="chevron-back"
        size={13}
        color={active === 'left' ? colors.accent : colors.text}
        style={styles.dpadLeft}
      />
      <Ionicons
        name="chevron-forward"
        size={13}
        color={active === 'right' ? colors.accent : colors.text}
        style={styles.dpadRight}
      />
      <View style={[styles.dpadCenter, active !== null && styles.dpadCenterActive]} />
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
  rail: {
    height: DPAD_SIZE,
    justifyContent: 'center',
  },
  clusterRow: {
    gap: 6,
    alignItems: 'center',
    paddingLeft: space.xs,
    // Keeps the last cluster reachable in front of the pinned controls.
    paddingRight: DPAD_SIZE + 40 + 6 * 3,
  },
  cluster: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 38,
    borderRadius: 999,
    backgroundColor: colors.surfaceRaised,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    paddingHorizontal: 2,
  },
  symbolPair: {
    flexDirection: 'row',
    alignItems: 'center',
    height: '100%',
  },
  segment: {
    minWidth: 44,
    height: '100%',
    paddingHorizontal: space.sm,
    alignItems: 'center',
    justifyContent: 'center',
  },
  segmentNarrow: {
    minWidth: 34,
    paddingHorizontal: space.xs,
  },
  segmentLabelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
  },
  segmentLabel: {
    color: colors.text,
    fontFamily: mono,
    fontSize: 12,
    fontWeight: '600',
  },
  divider: {
    width: StyleSheet.hairlineWidth,
    height: 20,
    backgroundColor: colors.border,
  },
  pressed: {
    opacity: 0.6,
  },
  fixedControls: {
    position: 'absolute',
    right: space.xs,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  circleButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.surfaceRaised,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  dpad: {
    width: DPAD_SIZE,
    height: DPAD_SIZE,
    borderRadius: DPAD_SIZE / 2,
    backgroundColor: colors.surfaceRaised,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dpadUp: {
    position: 'absolute',
    top: 3,
    alignSelf: 'center',
  },
  dpadDown: {
    position: 'absolute',
    bottom: 3,
    alignSelf: 'center',
  },
  dpadLeft: {
    position: 'absolute',
    left: 4,
    top: DPAD_SIZE / 2 - 6.5,
  },
  dpadRight: {
    position: 'absolute',
    right: 4,
    top: DPAD_SIZE / 2 - 6.5,
  },
  dpadCenter: {
    width: 12,
    height: 12,
    borderRadius: 6,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.bg,
  },
  dpadCenterActive: {
    borderColor: colors.accent,
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
