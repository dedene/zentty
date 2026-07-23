import { colors } from '@/theme';

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
