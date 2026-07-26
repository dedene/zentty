import { Stack } from 'expo-router';

import { stackScreenOptions } from '@/lib/navTheme';

export default function PairingLayout() {
  return (
    <Stack screenOptions={stackScreenOptions}>
      <Stack.Screen name="scan" options={{ title: 'Pair a Mac' }} />
    </Stack>
  );
}
