import { z } from 'zod';

// Shared value types referenced by more than one family. Everything here is a
// zod schema plus its inferred TS type, so the wire contract has a single source
// of truth for both runtime validation and static typing.

/** Per-direction protocol version window advertised at handshake. */
export const VersionRange = z.object({
  min: z.number().int(),
  max: z.number().int(),
});
export type VersionRange = z.infer<typeof VersionRange>;

/** LAN reachability hint carried in the pairing offer. */
export const LanHint = z.object({
  host: z.string(),
  port: z.number().int(),
});
export type LanHint = z.infer<typeof LanHint>;

/** A terminal grid measured in columns x rows. */
export const ViewportSize = z.object({
  cols: z.number().int(),
  rows: z.number().int(),
});
export type ViewportSize = z.infer<typeof ViewportSize>;

/** Mirrors PaneAgentState on the Mac side. */
export const PaneState = z.enum([
  'starting',
  'running',
  'needsInput',
  'unresolvedStop',
  'idle',
]);
export type PaneState = z.infer<typeof PaneState>;

/** What kind of human interaction a pane is waiting on. */
export const InteractionKind = z.enum([
  'none',
  'approval',
  'question',
  'decision',
  'auth',
  'genericInput',
]);
export type InteractionKind = z.infer<typeof InteractionKind>;

/** Mirrors `PaneAgentTaskProgress` on the Mac side. */
export const TaskProgress = z.object({
  completed: z.number().int().gte(0),
  total: z.number().int().gte(1),
});
export type TaskProgress = z.infer<typeof TaskProgress>;

/**
 * Compact per-pane descriptor sent in dashboard snapshots and deltas.
 *
 * `taskProgress` mirrors `PaneAgentTaskProgress` on the Mac side. Absent when
 * unknown.
 */
export const PaneSummary = z.object({
  paneId: z.string(),
  worklaneId: z.string(),
  title: z.string(),
  tool: z.string().optional(),
  state: PaneState,
  interactionKind: InteractionKind,
  requiresHumanAttention: z.boolean(),
  workingDirectory: z.string(),
  sessionId: z.string().optional(),
  hasTranscript: z.boolean(),
  taskProgress: TaskProgress.optional(),
});
export type PaneSummary = z.infer<typeof PaneSummary>;

/** Normalized, deliberately lossy transcript role. */
export const TranscriptRole = z.enum([
  'user',
  'assistant',
  'tool_use',
  'tool_result',
  'system',
]);
export type TranscriptRole = z.infer<typeof TranscriptRole>;

/**
 * One normalized transcript entry. Adapter-specific detail rides in `raw` only
 * when small; the typed fields are the cross-tool contract.
 */
export const TranscriptEntry = z.object({
  id: z.string(),
  role: TranscriptRole,
  ts: z.number().int().optional(),
  text: z.string().optional(),
  toolName: z.string().optional(),
  toolInput: z.unknown().optional(),
  toolResultSummary: z.string().optional(),
  status: z.string().optional(),
  raw: z.unknown().optional(),
});
export type TranscriptEntry = z.infer<typeof TranscriptEntry>;
