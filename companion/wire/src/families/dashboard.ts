import { z } from 'zod';
import { PaneSummary } from '../types';

// dashboard.* — full snapshot plus incremental deltas of agent state. Mac is
// server-authoritative.

/** phone -> mac. */
export const DashboardSubscribe = z.object({});

/** One worklane grouping in a snapshot. */
export const Worklane = z.object({
  id: z.string(),
  title: z.string(),
  windowId: z.number().int(),
  attention: z.boolean(),
  panes: z.array(PaneSummary),
});

/** mac -> phone. */
export const DashboardSnapshot = z.object({
  worklanes: z.array(Worklane),
});

/** mac -> phone. */
export const DashboardDelta = z.object({
  updated: z.array(PaneSummary),
  removedPaneIds: z.array(z.string()),
});

export const dashboardMessages = {
  'dashboard.subscribe': DashboardSubscribe,
  'dashboard.snapshot': DashboardSnapshot,
  'dashboard.delta': DashboardDelta,
} as const;
