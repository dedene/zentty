import { z } from 'zod';
import { ViewportSize } from '../types';

// lease.* — opt-in control takeover with reflow.

/** phone -> mac. Phone-measured natural grid; mac clamps ~20-500 x ~5-200. */
export const LeaseRequest = z.object({
  paneId: z.string(),
  cols: z.number().int(),
  rows: z.number().int(),
});

/** mac -> phone. */
export const LeaseGrant = z.object({
  paneId: z.string(),
  leaseId: z.string(),
  effective: ViewportSize,
  client: ViewportSize,
  isCurrentClientLimiting: z.boolean(),
  heartbeatIntervalMs: z.number().int(),
  expiryMs: z.number().int(),
});

/** phone -> mac. Keeps the lease alive. */
export const LeaseHeartbeat = z.object({
  leaseId: z.string(),
});

/** phone -> mac. Rotation / font change, debounced 300ms. */
export const LeaseResize = z.object({
  leaseId: z.string(),
  cols: z.number().int(),
  rows: z.number().int(),
});

/** phone -> mac. */
export const LeaseRelease = z.object({
  leaseId: z.string(),
});

export const LeaseRevokedReason = z.enum([
  'takeback',
  'expired',
  'pane_closed',
  'superseded',
]);
export type LeaseRevokedReason = z.infer<typeof LeaseRevokedReason>;

/** mac -> phone. */
export const LeaseRevoked = z.object({
  leaseId: z.string(),
  reason: LeaseRevokedReason,
});

export const leaseMessages = {
  'lease.request': LeaseRequest,
  'lease.grant': LeaseGrant,
  'lease.heartbeat': LeaseHeartbeat,
  'lease.resize': LeaseResize,
  'lease.release': LeaseRelease,
  'lease.revoked': LeaseRevoked,
} as const;
