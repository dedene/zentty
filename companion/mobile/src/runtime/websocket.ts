/**
 * WebSocket adapters for the two core transport seams:
 *
 * - {@link openTextSocket} → a {@link TextSocket} for the relay leg (JSON frames),
 *   handed to `openRelayTransport`.
 * - {@link openByteSocket} → a byte-level {@link TransportLike} for the direct-LAN
 *   leg (sealed session frames ride as binary WebSocket messages).
 *
 * Both convert the event-based `WebSocket` API into the pull-based `receive()`
 * the core expects, buffering inbound frames until a reader asks for them and
 * resolving `null` once the socket closes.
 */
import { utf8Bytes, type TextSocket, type TransportLike } from '@/core';

/** Single-consumer async queue: buffers pushed values, hands them to `receive()`. */
class FrameQueue<T> {
  private readonly buffer: T[] = [];
  private readonly waiters: Array<(value: T | null) => void> = [];
  private closed = false;

  push(value: T): void {
    const waiter = this.waiters.shift();
    if (waiter) {
      waiter(value);
    } else {
      this.buffer.push(value);
    }
  }

  end(): void {
    this.closed = true;
    let waiter = this.waiters.shift();
    while (waiter) {
      waiter(null);
      waiter = this.waiters.shift();
    }
  }

  receive(): Promise<T | null> {
    const next = this.buffer.shift();
    if (next !== undefined) {
      return Promise.resolve(next);
    }
    if (this.closed) {
      return Promise.resolve(null);
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

/**
 * Default ceiling on the WebSocket connect (TCP + upgrade) before we give up.
 * A peer that accepts the socket but never completes the handshake would
 * otherwise hang the caller forever. Matches the session handshake ceiling.
 */
export const DEFAULT_CONNECT_TIMEOUT_MS = 10_000;

/** Arm the connect deadline: on expiry, close the half-open socket and reject. */
function armConnectTimeout(
  ws: { close: () => void },
  url: string,
  connectTimeoutMs: number,
  reject: (error: Error) => void,
): ReturnType<typeof setTimeout> | undefined {
  if (connectTimeoutMs <= 0) {
    return undefined;
  }
  return setTimeout(() => {
    try {
      ws.close();
    } catch {
      // Closing a half-open socket must not mask the timeout error.
    }
    reject(new Error(`websocket connect timed out: ${url}`));
  }, connectTimeoutMs);
}

/** Open a text-framed WebSocket, resolving once the connection is established.
 * Rejects if the connect does not complete within `connectTimeoutMs`
 * (default {@link DEFAULT_CONNECT_TIMEOUT_MS}; `0` disables the deadline). */
export function openTextSocket(
  url: string,
  connectTimeoutMs: number = DEFAULT_CONNECT_TIMEOUT_MS,
): Promise<TextSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const queue = new FrameQueue<string>();
    let opened = false;
    const timer = armConnectTimeout(ws, url, connectTimeoutMs, reject);
    const clearTimer = (): void => {
      if (timer) {
        clearTimeout(timer);
      }
    };

    ws.onopen = () => {
      opened = true;
      clearTimer();
      resolve({
        send: (text: string) => {
          ws.send(text);
          return Promise.resolve();
        },
        receive: () => queue.receive(),
        close: () => ws.close(),
      });
    };
    ws.onmessage = (event) => {
      const data: unknown = event.data;
      queue.push(typeof data === 'string' ? data : String(data));
    };
    ws.onerror = () => {
      if (!opened) {
        clearTimer();
        reject(new Error(`websocket connect failed: ${url}`));
      }
    };
    ws.onclose = () => queue.end();
  });
}

/** Open a binary WebSocket as a byte-level transport, resolving once connected.
 * Same connect deadline as {@link openTextSocket}. */
export function openByteSocket(
  url: string,
  connectTimeoutMs: number = DEFAULT_CONNECT_TIMEOUT_MS,
): Promise<TransportLike> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const queue = new FrameQueue<Uint8Array>();
    let opened = false;
    const timer = armConnectTimeout(ws, url, connectTimeoutMs, reject);
    const clearTimer = (): void => {
      if (timer) {
        clearTimeout(timer);
      }
    };

    ws.onopen = () => {
      opened = true;
      clearTimer();
      resolve({
        send: (frame: Uint8Array) => {
          ws.send(frame);
          return Promise.resolve();
        },
        receive: () => queue.receive(),
        close: () => ws.close(),
      });
    };
    ws.onmessage = (event) => {
      const data: unknown = event.data;
      if (data instanceof ArrayBuffer) {
        queue.push(new Uint8Array(data));
      } else if (typeof data === 'string') {
        queue.push(utf8Bytes(data));
      }
    };
    ws.onerror = () => {
      if (!opened) {
        clearTimer();
        reject(new Error(`websocket connect failed: ${url}`));
      }
    };
    ws.onclose = () => queue.end();
  });
}
