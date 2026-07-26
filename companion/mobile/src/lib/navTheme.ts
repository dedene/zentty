import { DarkTheme, type Theme } from 'expo-router';

import { colors } from '@/theme';

/**
 * Navigation theme for the root `ThemeProvider`. Without it, expo-router's
 * container falls back to the light `DefaultTheme`, whose white `background`/
 * `card` peek through at the screen edges during stack transitions and flash
 * on header buttons before per-screen options apply — `contentStyle` alone
 * only paints each screen's content view, not the transition chrome.
 */
export const navTheme: Theme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    primary: colors.accent,
    background: colors.bg,
    card: colors.bg,
    text: colors.text,
    border: colors.border,
  },
};

/**
 * Shared dark header/content styling applied to every native stack. Typed
 * structurally (not against @react-navigation) so it stays a direct-dependency-
 * free object that expo-router's `screenOptions` accepts.
 */
export const stackScreenOptions = {
  headerStyle: { backgroundColor: colors.bg },
  headerTitleStyle: { color: colors.text },
  headerTintColor: colors.accent,
  headerShadowVisible: false,
  contentStyle: { backgroundColor: colors.bg },
} as const;
