import { z } from 'zod';

// pane.* — the plain-text terminal lane.

/** phone -> mac. */
export const PaneWatch = z.object({
  paneId: z.string(),
});

/** phone -> mac. */
export const PaneUnwatch = z.object({
  paneId: z.string(),
});

/** mac -> phone. Full viewport text per debounced change; `seq` monotonic per pane. */
export const PaneText = z.object({
  paneId: z.string(),
  seq: z.number().int(),
  viewport: z.string(),
  cursorRow: z.number().int().optional(),
  gridCols: z.number().int(),
  gridRows: z.number().int(),
  truncatedScrollback: z.boolean(),
});

/** phone -> mac request half of pane.scrollback. */
export const PaneScrollbackRequest = z.object({
  paneId: z.string(),
  lineLimit: z.number().int(),
});

/** mac -> phone reply half of pane.scrollback. */
export const PaneScrollbackReply = z.object({
  paneId: z.string(),
  text: z.string(),
});

/**
 * `pane.scrollback` is a request/reply pair sharing one type name in the draft.
 * Modeled as a union so a single registry entry validates either half.
 */
export const PaneScrollback = z.union([
  PaneScrollbackRequest,
  PaneScrollbackReply,
]);

export const paneMessages = {
  'pane.watch': PaneWatch,
  'pane.unwatch': PaneUnwatch,
  'pane.text': PaneText,
  'pane.scrollback': PaneScrollback,
} as const;
