/** @jest-environment node */
import { afterEach, beforeEach, describe, expect, it, jest } from '@jest/globals';

import { openByteSocket, openTextSocket } from '../websocket';

/**
 * Minimal scriptable stand-in for the global WebSocket: instances record
 * themselves on construction so the test can fire `onopen`/`onerror` (or stay
 * silent to exercise the connect deadline).
 */
class FakeWebSocket {
  static instances: FakeWebSocket[] = [];

  onopen: (() => void) | null = null;
  onmessage: ((event: { data: unknown }) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  binaryType = '';
  closed = false;
  readonly url: string;

  constructor(url: string) {
    this.url = url;
    FakeWebSocket.instances.push(this);
  }

  send(_data: unknown): void {
    // no-op
  }

  close(): void {
    this.closed = true;
  }
}

const globalWithSocket = globalThis as { WebSocket?: unknown };

describe('websocket connect timeout', () => {
  let original: unknown;

  beforeEach(() => {
    original = globalWithSocket.WebSocket;
    globalWithSocket.WebSocket = FakeWebSocket;
    FakeWebSocket.instances = [];
  });

  afterEach(() => {
    globalWithSocket.WebSocket = original;
  });

  it('rejects and closes a text socket that never finishes connecting', async () => {
    jest.useFakeTimers();
    try {
      const p = openTextSocket('ws://10.0.0.2:7777', 3_000);
      const assertion = expect(p).rejects.toThrow('websocket connect timed out');

      await jest.advanceTimersByTimeAsync(3_000);
      await assertion;
      expect(FakeWebSocket.instances[0]?.closed).toBe(true);
    } finally {
      jest.useRealTimers();
    }
  });

  it('rejects and closes a byte socket that never finishes connecting', async () => {
    jest.useFakeTimers();
    try {
      const p = openByteSocket('ws://10.0.0.2:7777', 3_000);
      const assertion = expect(p).rejects.toThrow('websocket connect timed out');

      await jest.advanceTimersByTimeAsync(3_000);
      await assertion;
      expect(FakeWebSocket.instances[0]?.closed).toBe(true);
    } finally {
      jest.useRealTimers();
    }
  });

  it('resolves when the socket opens before the deadline', async () => {
    jest.useFakeTimers();
    try {
      const p = openTextSocket('ws://10.0.0.2:7777', 3_000);
      FakeWebSocket.instances[0]?.onopen?.();
      const socket = await p;
      await socket.send('hello');

      // The deadline was disarmed: advancing far past it must not reject or close.
      await jest.advanceTimersByTimeAsync(60_000);
      expect(FakeWebSocket.instances[0]?.closed).toBe(false);
      socket.close();
    } finally {
      jest.useRealTimers();
    }
  });

  it('still rejects immediately on a pre-open error', async () => {
    const p = openTextSocket('ws://10.0.0.2:7777', 3_000);
    const assertion = expect(p).rejects.toThrow('websocket connect failed');
    FakeWebSocket.instances[0]?.onerror?.();
    await assertion;
  });
});
