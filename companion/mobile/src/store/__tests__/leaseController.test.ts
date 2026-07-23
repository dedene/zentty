import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';

import { LeaseController, type LeaseGrantData, type LeaseSnapshot } from '../leaseController';

function grant(overrides: Partial<LeaseGrantData> = {}): LeaseGrantData {
  return {
    leaseId: 'L1',
    effective: { cols: 45, rows: 60 },
    client: { cols: 45, rows: 60 },
    isCurrentClientLimiting: true,
    heartbeatIntervalMs: 5000,
    expiryMs: 15000,
    ...overrides,
  };
}

describe('LeaseController', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });
  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  it('grants, then heartbeats on the granted interval', async () => {
    const sendHeartbeat = jest.fn();
    const controller = new LeaseController({
      requestGrant: async () => grant(),
      sendHeartbeat,
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });

    await controller.request(45, 60);
    expect(controller.snapshot.status).toBe('held');
    expect(controller.snapshot.leaseId).toBe('L1');
    expect(controller.snapshot.effective).toEqual({ cols: 45, rows: 60 });

    jest.advanceTimersByTime(5000);
    expect(sendHeartbeat).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(5000);
    expect(sendHeartbeat).toHaveBeenCalledTimes(2);
    expect(sendHeartbeat).toHaveBeenCalledWith('L1');
  });

  it('drops to read-only on revoke and stops heartbeating', async () => {
    const sendHeartbeat = jest.fn();
    const states: LeaseSnapshot[] = [];
    const controller = new LeaseController({
      requestGrant: async () => grant(),
      sendHeartbeat,
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: (s) => states.push(s),
    });

    await controller.request(45, 60);
    jest.advanceTimersByTime(5000);
    expect(sendHeartbeat).toHaveBeenCalledTimes(1);

    controller.handleRevoked('L1', 'takeback');
    expect(controller.snapshot.status).toBe('readonly');
    expect(controller.snapshot.revokedReason).toBe('takeback');

    jest.advanceTimersByTime(20000);
    expect(sendHeartbeat).toHaveBeenCalledTimes(1); // no further beats
    expect(states.some((s) => s.status === 'readonly')).toBe(true);
  });

  it('ignores a revoke for a different lease', async () => {
    const controller = new LeaseController({
      requestGrant: async () => grant({ leaseId: 'MINE' }),
      sendHeartbeat: jest.fn(),
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });
    await controller.request(45, 60);
    controller.handleRevoked('OTHER', 'expired');
    expect(controller.snapshot.status).toBe('held');
  });

  it('releases: sends release, stops heartbeat, returns to idle', async () => {
    const sendHeartbeat = jest.fn();
    const sendRelease = jest.fn();
    const controller = new LeaseController({
      requestGrant: async () => grant(),
      sendHeartbeat,
      sendResize: jest.fn(),
      sendRelease,
      onChange: () => {},
    });
    await controller.request(45, 60);
    controller.release();
    expect(sendRelease).toHaveBeenCalledWith('L1');
    expect(controller.snapshot.status).toBe('idle');
    jest.advanceTimersByTime(20000);
    expect(sendHeartbeat).not.toHaveBeenCalled();
  });

  it('debounces resize to a single send', async () => {
    const sendResize = jest.fn();
    const controller = new LeaseController({
      requestGrant: async () => grant(),
      sendHeartbeat: jest.fn(),
      sendResize,
      sendRelease: jest.fn(),
      onChange: () => {},
      resizeDebounceMs: 300,
    });
    await controller.request(45, 60);

    controller.resize(30, 40);
    controller.resize(28, 44);
    jest.advanceTimersByTime(299);
    expect(sendResize).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1);
    expect(sendResize).toHaveBeenCalledTimes(1);
    expect(sendResize).toHaveBeenCalledWith('L1', 28, 44);
    expect(controller.snapshot.effective).toEqual({ cols: 28, rows: 44 });
  });

  it('reports an error when the grant request fails', async () => {
    const controller = new LeaseController({
      requestGrant: async () => {
        throw new Error('session not ready');
      },
      sendHeartbeat: jest.fn(),
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });
    await controller.request(45, 60);
    expect(controller.snapshot.status).toBe('idle');
    expect(controller.snapshot.error).toBe('session not ready');
  });
});
