import { z } from 'zod';
import { TranscriptEntry } from '../types';

// transcript.* — normalized conversation view for adapted tools.

/** phone -> mac. */
export const TranscriptSubscribe = z.object({
  paneId: z.string(),
});

/** mac -> phone, initial full state. */
export const TranscriptSnapshot = z.object({
  paneId: z.string(),
  sessionId: z.string(),
  entries: z.array(TranscriptEntry),
  truncated: z.boolean(),
});

/** mac -> phone, incremental. */
export const TranscriptDelta = z.object({
  paneId: z.string(),
  entries: z.array(TranscriptEntry),
});

export const TranscriptUnavailableReason = z.enum([
  'no_adapter',
  'session_ended',
  'file_missing',
]);
export type TranscriptUnavailableReason = z.infer<
  typeof TranscriptUnavailableReason
>;

/** mac -> phone. */
export const TranscriptUnavailable = z.object({
  paneId: z.string(),
  reason: TranscriptUnavailableReason,
});

export const transcriptMessages = {
  'transcript.subscribe': TranscriptSubscribe,
  'transcript.snapshot': TranscriptSnapshot,
  'transcript.delta': TranscriptDelta,
  'transcript.unavailable': TranscriptUnavailable,
} as const;
