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

  it('degrades to read-only when the transport stays down past the lease expiry', async () => {
    let ready = true;
    let now = 0;
    const sendHeartbeat = jest.fn();
    const controller = new LeaseController({
      requestGrant: async () => grant({ heartbeatIntervalMs: 5000, expiryMs: 15000 }),
      sendHeartbeat,
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
      isReady: () => ready,
      now: () => now,
    });

    await controller.request(45, 60); // granted at now=0
    ready = false; // session drops; beats can no longer reach the Mac

    now = 5000;
    jest.advanceTimersByTime(5000);
    expect(controller.snapshot.status).toBe('held'); // 5s gap < 15s expiry
    now = 10000;
    jest.advanceTimersByTime(5000);
    expect(controller.snapshot.status).toBe('held'); // 10s gap < 15s expiry

    now = 15000;
    jest.advanceTimersByTime(5000);
    expect(controller.snapshot.status).toBe('readonly'); // 15s gap >= expiry
    expect(controller.snapshot.revokedReason).toBe('expired');

    // No heartbeats were sent while down, and none resume after degrading.
    expect(sendHeartbeat).not.toHaveBeenCalled();
    now = 60000;
    jest.advanceTimersByTime(30000);
    expect(sendHeartbeat).not.toHaveBeenCalled();
  });

  it('reconcile re-requests a fresh grant and renews a held lease', async () => {
    let leaseId = 'L1';
    const controller = new LeaseController({
      requestGrant: async () => grant({ leaseId }),
      sendHeartbeat: jest.fn(),
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });
    await controller.request(45, 60);
    expect(controller.snapshot.leaseId).toBe('L1');

    leaseId = 'L2'; // the Mac issues a new lease on re-request after reconnect
    await controller.reconcile();
    expect(controller.snapshot.status).toBe('held');
    expect(controller.snapshot.leaseId).toBe('L2');
  });

  it('reconcile degrades to read-only when the Mac cannot renew the lease', async () => {
    let fail = false;
    const controller = new LeaseController({
      requestGrant: async () => {
        if (fail) {
          throw new Error('unknown lease');
        }
        return grant();
      },
      sendHeartbeat: jest.fn(),
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });
    await controller.request(45, 60);
    fail = true; // the Mac already expired the lease during the reconnect gap
    await controller.reconcile();
    expect(controller.snapshot.status).toBe('readonly');
    expect(controller.snapshot.revokedReason).toBe('expired');
  });

  it('reconcile is a no-op when no lease is held', async () => {
    const requestGrant = jest.fn(async () => grant());
    const controller = new LeaseController({
      requestGrant,
      sendHeartbeat: jest.fn(),
      sendResize: jest.fn(),
      sendRelease: jest.fn(),
      onChange: () => {},
    });
    await controller.reconcile();
    expect(requestGrant).not.toHaveBeenCalled();
    expect(controller.snapshot.status).toBe('idle');
  });

  it('release cancels a pending acquire and releases the orphaned grant', async () => {
    const sendRelease = jest.fn();
    const sendHeartbeat = jest.fn();
    let resolveGrant!: (g: LeaseGrantData) => void;
    const controller = new LeaseController({
      requestGrant: () => new Promise<LeaseGrantData>((res) => (resolveGrant = res)),
      sendHeartbeat,
      sendResize: jest.fn(),
      sendRelease,
      onChange: () => {},
    });

    const pending = controller.request(45, 60);
    expect(controller.snapshot.status).toBe('requesting');

    controller.release(); // left the screen before the grant landed
    expect(controller.snapshot.status).toBe('idle');

    resolveGrant(grant({ leaseId: 'ORPHAN' }));
    await pending;

    // The lease never binds, and the orphaned grant is proactively released
    // instead of leaking until the Mac's heartbeat expiry.
    expect(sendRelease).toHaveBeenCalledWith('ORPHAN');
    expect(controller.snapshot.status).toBe('idle');
    jest.advanceTimersByTime(20000);
    expect(sendHeartbeat).not.toHaveBeenCalled();
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
