import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';

import type { ParsedMessage } from '@zentty/wire';

import { PaneController, type PaneRuntimeState, type PaneTransport } from '../paneController';

function makeTransport(overrides: Partial<PaneTransport> = {}): PaneTransport {
  return {
    send: jest.fn(),
    request: jest.fn(async () => ({ v: 1, id: '1', type: 'pane.scrollback', payload: {} }) as ParsedMessage),
    isReady: () => true,
    ...overrides,
  };
}

describe('PaneController.fetchScrollback', () => {
  let warnSpy: jest.SpiedFunction<typeof console.warn>;

  beforeEach(() => {
    warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => {
    warnSpy.mockRestore();
  });

  it('sets scrollbackError on a failed request and logs a warning', async () => {
    const transport = makeTransport({
      request: jest.fn(async () => {
        throw new Error('boom');
      }),
    });
    const states: PaneRuntimeState[] = [];
    const controller = new PaneController('pane1', transport, (s) => states.push(s));

    await controller.fetchScrollback();

    expect(controller.state.scrollbackError).toBe(true);
    expect(controller.state.scrollbackLoading).toBe(false);
    expect(warnSpy).toHaveBeenCalledTimes(1);
    expect(states.some((s) => s.scrollbackError === true)).toBe(true);
  });

  it('clears a prior scrollbackError on the next successful fetch', async () => {
    let fail = true;
    const transport = makeTransport({
      request: jest.fn(async () => {
        if (fail) {
          throw new Error('boom');
        }
        return { v: 1, id: '1', type: 'pane.scrollback', payload: { text: 'hello' } } as ParsedMessage;
      }),
    });
    const controller = new PaneController('pane1', transport, () => {});

    await controller.fetchScrollback();
    expect(controller.state.scrollbackError).toBe(true);

    fail = false;
    await controller.fetchScrollback();

    expect(controller.state.scrollbackError).toBe(false);
    expect(controller.state.text?.scrollback).toBe('hello');
  });

  it('leaves scrollbackError false on the ordinary success path', async () => {
    const transport = makeTransport({
      request: jest.fn(
        async () => ({ v: 1, id: '1', type: 'pane.scrollback', payload: { text: 'abc' } }) as ParsedMessage,
      ),
    });
    const controller = new PaneController('pane1', transport, () => {});

    await controller.fetchScrollback();

    expect(controller.state.scrollbackError).toBe(false);
    expect(controller.state.scrollbackLoading).toBe(false);
    expect(controller.state.text?.scrollback).toBe('abc');
  });

  it('clears scrollbackError when the pane is re-watched', () => {
    const transport = makeTransport();
    const controller = new PaneController('pane1', transport, () => {});
    controller.state = { ...controller.state, scrollbackError: true };

    controller.watch();

    expect(controller.state.scrollbackError).toBe(false);
  });
});

describe('PaneController input frames', () => {
  // The phone sends *semantic* keys; the Mac decides the bytes (routing control
  // keys through a real key event so ESC/CR survive). These assert the exact
  // wire frame per intent — the contract the Mac-side router depends on.
  it('sends a named key as input.key, never raw escape-sequence text', () => {
    const send = jest.fn();
    const controller = new PaneController('pane1', makeTransport({ send }), () => {});

    for (const key of ['up', 'down', 'left', 'right', 'enter', 'escape', 'tab', 'ctrl_c'] as const) {
      controller.sendKey(key);
    }

    expect(send.mock.calls).toEqual([
      ['input.key', { paneId: 'pane1', key: 'up' }],
      ['input.key', { paneId: 'pane1', key: 'down' }],
      ['input.key', { paneId: 'pane1', key: 'left' }],
      ['input.key', { paneId: 'pane1', key: 'right' }],
      ['input.key', { paneId: 'pane1', key: 'enter' }],
      ['input.key', { paneId: 'pane1', key: 'escape' }],
      ['input.key', { paneId: 'pane1', key: 'tab' }],
      ['input.key', { paneId: 'pane1', key: 'ctrl_c' }],
    ]);
  });

  it('sends typed text and symbols as input.text', () => {
    const send = jest.fn();
    const controller = new PaneController('pane1', makeTransport({ send }), () => {});

    controller.sendText('hello');
    controller.sendText('|');

    expect(send.mock.calls).toEqual([
      ['input.text', { paneId: 'pane1', text: 'hello' }],
      ['input.text', { paneId: 'pane1', text: '|' }],
    ]);
  });

  it('sends a quick action as input.quickAction', () => {
    const send = jest.fn();
    const controller = new PaneController('pane1', makeTransport({ send }), () => {});

    controller.quickAction('approve');

    expect(send).toHaveBeenCalledWith('input.quickAction', { paneId: 'pane1', actionId: 'approve' });
  });
});

/** Flush pending microtasks so the fire-and-forget lease requests settle. */
const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

function bytesAttached(overrides: Record<string, unknown> = {}): ParsedMessage {
  return {
    v: 1,
    id: 'r',
    type: 'pane.bytes.attached',
    payload: {
      paneId: 'p',
      epoch: 'e1',
      startSeq: 0,
      replay: '',
      truncated: false,
      ...overrides,
    },
  } as ParsedMessage;
}

describe('PaneController byte lane lifecycle', () => {
  it('attachBytes then dispose sends detach', async () => {
    const send = jest.fn();
    const request = jest.fn(async () => bytesAttached());
    const controller = new PaneController('p', makeTransport({ send, request }), () => {});
    controller.attachBytes({
      onWrite: () => {},
      onReset: () => {},
      onUnsupported: () => {},
    });
    await flush();
    controller.dispose();
    expect(send).toHaveBeenCalledWith('pane.bytes.detach', { paneId: 'p' });
  });

  it('second attachBytes rebinds without orphaning (single live lane)', async () => {
    const send = jest.fn();
    const request = jest.fn(async () => bytesAttached());
    const controller = new PaneController('p', makeTransport({ send, request }), () => {});
    const writesA: string[] = [];
    const writesB: string[] = [];
    controller.attachBytes({
      onWrite: (d) => writesA.push(d),
      onReset: () => {},
      onUnsupported: () => {},
    });
    await flush();
    controller.attachBytes({
      onWrite: (d) => writesB.push(d),
      onReset: () => {},
      onUnsupported: () => {},
    });
    await flush();
    // Rebind + resync: may detach-and-reattach only if first was dead; otherwise
    // warm resync. Detach count stays low (not one detach per rebind storm).
    const detaches = send.mock.calls.filter((c) => c[0] === 'pane.bytes.detach');
    expect(detaches.length).toBeLessThanOrEqual(1);
    expect(request.mock.calls.length).toBeGreaterThanOrEqual(2);
    controller.dispose();
  });

  it('onUnsupported detaches the lane and stops probing', async () => {
    const send = jest.fn();
    const request = jest.fn(async () => ({ v: 1, id: 'r', type: 'session.error', payload: {} }) as ParsedMessage);
    const controller = new PaneController('p', makeTransport({ send, request }), () => {});
    let unsupported = 0;
    controller.attachBytes({
      onWrite: () => {},
      onReset: () => {},
      onUnsupported: () => {
        unsupported += 1;
      },
    });
    await flush();
    expect(unsupported).toBe(1);
    expect(send).toHaveBeenCalledWith('pane.bytes.detach', { paneId: 'p' });
    // resync after permanent fallback must not re-attach.
    const callsBefore = request.mock.calls.length;
    controller.resync();
    await flush();
    expect(request.mock.calls.length).toBe(callsBefore);
    controller.dispose();
  });

  it('unwatch detaches the byte lane', async () => {
    const send = jest.fn();
    const request = jest.fn(async () => bytesAttached());
    const controller = new PaneController('p', makeTransport({ send, request }), () => {});
    controller.watch();
    controller.attachBytes({
      onWrite: () => {},
      onReset: () => {},
      onUnsupported: () => {},
    });
    await flush();
    controller.unwatch();
    expect(send).toHaveBeenCalledWith('pane.bytes.detach', { paneId: 'p' });
    controller.dispose();
  });
});

function leaseGrant(overrides: Record<string, unknown> = {}): ParsedMessage {
  return {
    v: 1,
    id: '1',
    type: 'lease.grant',
    payload: {
      leaseId: 'L1',
      effective: { cols: 40, rows: 30 },
      client: { cols: 40, rows: 30 },
      isCurrentClientLimiting: false,
      heartbeatIntervalMs: 5000,
      expiryMs: 15000,
      ...overrides,
    },
  } as ParsedMessage;
}

describe('PaneController implicit control', () => {
  it('acquires control once watched, a viewport is set, and the session is ready', async () => {
    const request = jest.fn(async () => leaseGrant());
    const controller = new PaneController('p', makeTransport({ request }), () => {});

    controller.watch();
    controller.acquireControl(); // no viewport yet — nothing to request at
    await flush();
    expect(request).not.toHaveBeenCalled();

    controller.setViewport(40, 30); // grid measured -> implicit acquire
    await flush();
    expect(request).toHaveBeenCalledWith('lease.request', { paneId: 'p', cols: 40, rows: 30 });
    expect(controller.state.lease.status).toBe('held');
    controller.dispose();
  });

  it('does not acquire while the transport is down, then acquires on resync', async () => {
    let ready = false;
    const request = jest.fn(async () => leaseGrant());
    const controller = new PaneController('p', makeTransport({ request, isReady: () => ready }), () => {});

    controller.watch();
    controller.acquireControl();
    controller.setViewport(40, 30);
    await flush();
    expect(request).not.toHaveBeenCalled(); // offline: deferred

    ready = true;
    controller.resync(); // session back
    await flush();
    expect(request).toHaveBeenCalledTimes(1);
    expect(controller.state.lease.status).toBe('held');
    controller.dispose();
  });

  it('releases control and clears intent on unwatch, and does not re-acquire on resync', async () => {
    const request = jest.fn(async () => leaseGrant());
    const send = jest.fn();
    const controller = new PaneController('p', makeTransport({ request, send }), () => {});

    controller.watch();
    controller.acquireControl();
    controller.setViewport(40, 30);
    await flush();
    expect(controller.state.lease.status).toBe('held');

    controller.unwatch();
    expect(send).toHaveBeenCalledWith('lease.release', { leaseId: 'L1' });
    expect(controller.state.lease.status).toBe('idle');

    controller.resync(); // a late reconnect must not re-take control after leaving
    await flush();
    expect(request).toHaveBeenCalledTimes(1);
    controller.dispose();
  });

  it('surfaces a denied lease as an error state without looping', async () => {
    const request = jest.fn(async () => {
      throw new Error('control refused');
    });
    const controller = new PaneController('p', makeTransport({ request }), () => {});

    controller.watch();
    controller.acquireControl();
    controller.setViewport(40, 30);
    await flush();
    expect(controller.state.lease.status).toBe('idle');
    expect(controller.state.lease.error).toBe('control refused');

    // A refusal must not spin into a request loop on the next measure.
    controller.setViewport(38, 30);
    await flush();
    expect(request).toHaveBeenCalledTimes(1);
    controller.dispose();
  });

  it('retries a denied lease when the indicator is tapped', async () => {
    let fail = true;
    const request = jest.fn(async () => {
      if (fail) {
        throw new Error('control refused');
      }
      return leaseGrant({ leaseId: 'L2' });
    });
    const controller = new PaneController('p', makeTransport({ request }), () => {});

    controller.watch();
    controller.acquireControl();
    controller.setViewport(40, 30);
    await flush();
    expect(controller.state.lease.error).toBe('control refused');

    fail = false;
    controller.retryControl();
    await flush();
    expect(controller.state.lease.status).toBe('held');
    expect(controller.state.lease.leaseId).toBe('L2');
    controller.dispose();
  });

  it('re-acquires (renews) control after a reconnect while focused', async () => {
    let leaseId = 'L1';
    const request = jest.fn(async () => leaseGrant({ leaseId }));
    const controller = new PaneController('p', makeTransport({ request }), () => {});

    controller.watch();
    controller.acquireControl();
    controller.setViewport(40, 30);
    await flush();
    expect(controller.state.lease.leaseId).toBe('L1');

    leaseId = 'L2'; // the Mac issues a fresh lease on the post-reconnect renew
    controller.resync();
    await flush();
    expect(controller.state.lease.status).toBe('held');
    expect(controller.state.lease.leaseId).toBe('L2');
    expect(request).toHaveBeenCalledTimes(2);
    controller.dispose();
  });
});
