import { Ionicons } from '@expo/vector-icons';
import { Stack, router } from 'expo-router';
import { Pressable } from 'react-native';

import { stackScreenOptions } from '@/lib/navTheme';
import { colors, space } from '@/theme';

export default function MainLayout() {
  return (
    <Stack screenOptions={stackScreenOptions}>
      <Stack.Screen
        name="index"
        options={{
          title: 'Macs',
          headerRight: () => (
            <Pressable
              onPress={() => router.push('/settings')}
              hitSlop={space.md}
              accessibilityLabel="Settings"
            >
              <Ionicons name="settings-outline" size={22} color={colors.accent} />
            </Pressable>
          ),
        }}
      />
      <Stack.Screen name="mac/[deviceId]" options={{ title: 'Dashboard' }} />
      <Stack.Screen name="pane/[paneId]" options={{ title: 'Pane' }} />
      <Stack.Screen
        name="settings"
        options={{ title: 'Settings', presentation: 'modal' }}
      />
    </Stack>
  );
}
