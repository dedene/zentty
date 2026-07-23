import { Platform, StyleSheet } from 'react-native';

/**
 * Dark-first terminal design tokens for the Zentty companion.
 *
 * The app commits to a single dark aesthetic on purpose: it is a control surface
 * for a terminal multiplexer, so it should read like one everywhere. Color is
 * restrained — surfaces are near-black, text is a small grey ramp, and saturated
 * hues are reserved for state badges (running / attention / stopped / online).
 */

export const colors = {
  /** App background — the deepest surface. */
  bg: '#0B0D10',
  /** Card / row surface. */
  surface: '#14171C',
  /** Raised surface (pressed rows, inputs). */
  surfaceRaised: '#1C2027',
  /** Hairline dividers and card borders. */
  border: '#262B33',

  text: '#E6E9EF',
  textDim: '#9AA3B2',
  textFaint: '#5C6675',

  /** Brand accent (Zentty blue, brightened for dark surfaces). */
  accent: '#5B9DF9',
  accentDim: '#2B486B',

  // State hues — the only saturated color in the UI.
  running: '#5B9DF9',
  attention: '#F5A623',
  stopped: '#FF5C5C',
  idle: '#6B7482',
  starting: '#8A79E0',

  online: '#3FB950',
  offline: '#6B7482',

  danger: '#FF5C5C',
} as const;

export const space = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
} as const;

export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  pill: 999,
} as const;

/** Monospaced family for terminal-flavored text (titles, codes, working dirs). */
export const mono = Platform.select({
  ios: 'Menlo',
  android: 'monospace',
  default: 'monospace',
}) as string;

export const type = StyleSheet.create({
  screenTitle: {
    fontSize: 28,
    fontWeight: '700',
    color: colors.text,
    letterSpacing: -0.5,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.textDim,
    letterSpacing: 0.3,
    textTransform: 'uppercase',
  },
  rowTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: colors.text,
  },
  mono: {
    fontFamily: mono,
    fontSize: 13,
    color: colors.textDim,
  },
  body: {
    fontSize: 15,
    color: colors.text,
  },
  dim: {
    fontSize: 13,
    color: colors.textDim,
  },
  faint: {
    fontSize: 12,
    color: colors.textFaint,
  },
});
