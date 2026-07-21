import { createServer, type Server as HttpServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { WebSocketServer, WebSocket, type RawData } from 'ws';
import {
  parseRelayFrame,
  type AnyRelayFrame,
  type RelayError as RelayErrorFrame,
  type RelayErrorCode,
  type RelayReady,
  type RelayDenied,
  type RelayChallenge,
  type RelayPeerStatus,
  type RelayFrame,
} from '@zentty/wire';
import type { RelayConfig } from './config.js';
import { createLogger, type Logger } from './log.js';
import { DeviceLimiter } from './rateLimit.js';
import { classifySealed, verifyRelayAuth } from './crypto.js';
import type { PushGateway } from './push/gateway.js';

// The relay: a zero-knowledge WebSocket router. Per connection it runs a small
// state machine (challenge -> auth -> ready), then routes relay.frame messages
// between authenticated devices by deviceId, stamping the authenticated sender
// into `from`. It tracks peer online status and never inspects the E2E `sealed`
// payload — except to classify plaintext `pairing.*` frames for the tighter
// pairing rate window (see crypto.classifySealed).

interface Conn {
  ws: WebSocket;
  nonce: string;
  deviceId: string | null;
  limiter: DeviceLimiter | null;
}

export interface RelayServerHandle {
  readonly httpServer: HttpServer;
  readonly wss: WebSocketServer;
  /** Begin listening; resolves with the bound port (useful with PORT=0). */
  listen(): Promise<number>;
  /** Close all sockets and the HTTP server. */
  close(): Promise<void>;
  /** Count of currently authenticated devices (diagnostics/tests). */
  onlineCount(): number;
}

export function createRelayServer(
  config: RelayConfig,
  logger: Logger = createLogger(config.logLevel),
  gateway?: PushGateway,
): RelayServerHandle {
  // deviceId -> its current authenticated connection (latest wins).
  const devices = new Map<string, Conn>();
  // target deviceId -> set of watcher deviceIds subscribed to its status.
  const watchers = new Map<string, Set<string>>();

  function send(conn: Conn, frame: AnyRelayFrame): void {
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(JSON.stringify(frame));
    }
  }

  function sendError(conn: Conn, code: RelayErrorCode, message: string): void {
    const frame: RelayErrorFrame = { type: 'relay.error', code, message };
    send(conn, frame);
  }

  /** Notify a (possibly offline) watcher of a peer's status, if it is online. */
  function notify(watcherId: string, deviceId: string, online: boolean): void {
    const watcher = devices.get(watcherId);
    if (!watcher) {
      return;
    }
    const frame: RelayPeerStatus = { type: 'relay.peerStatus', deviceId, online };
    send(watcher, frame);
  }

  /** Register `watcherId` as a subscriber to `targetId`; returns true if new. */
  function addWatch(watcherId: string, targetId: string): boolean {
    let set = watchers.get(targetId);
    if (!set) {
      set = new Set();
      watchers.set(targetId, set);
    }
    if (set.has(watcherId)) {
      return false;
    }
    set.add(watcherId);
    return true;
  }

  function handleAuth(conn: Conn, frame: AnyRelayFrame): void {
    if (frame.type !== 'relay.auth') {
      return;
    }
    if (!verifyRelayAuth(frame, conn.nonce)) {
      const denied: RelayDenied = {
        type: 'relay.denied',
        reason: 'authentication failed',
      };
      send(conn, denied);
      conn.ws.close();
      logger.warn('auth denied', { deviceId: frame.deviceId });
      return;
    }
    const deviceId = frame.deviceId;
    // Replace any prior connection for this device (latest wins). The old
    // socket's close handler is a no-op because devices no longer maps to it.
    const prior = devices.get(deviceId);
    conn.deviceId = deviceId;
    conn.limiter = new DeviceLimiter(config);
    devices.set(deviceId, conn);
    if (prior && prior !== conn) {
      prior.ws.close();
    }
    const ready: RelayReady = { type: 'relay.ready', deviceId };
    send(conn, ready);
    logger.info('device authed', { deviceId, online: devices.size });
    // Anyone already watching this device learns it is online now.
    const set = watchers.get(deviceId);
    if (set) {
      for (const watcherId of set) {
        notify(watcherId, deviceId, true);
      }
    }
  }

  function handleFrame(conn: Conn, frame: RelayFrame, wireBytes: number): void {
    const from = conn.deviceId as string;
    const limiter = conn.limiter as DeviceLimiter;
    const to = frame.to;

    if (wireBytes > config.maxFrameBytes) {
      sendError(conn, 'frame_too_large', 'frame exceeds size cap');
      return;
    }
    const sealed = classifySealed(frame.sealed, config.maxPairingSealedBytes);
    if (sealed.pairingTooLarge) {
      sendError(conn, 'frame_too_large', 'pairing payload exceeds cap');
      return;
    }
    const decision = limiter.admit(wireBytes, sealed.isPairing);
    if (!decision.ok) {
      sendError(conn, decision.reason ?? 'rate_limited', 'rate limit exceeded');
      return;
    }

    const target = devices.get(to);
    // Devices implicitly subscribe to peers they exchange frames with.
    const senderIsNew = addWatch(from, to);
    addWatch(to, from);

    if (!target) {
      // No store-and-forward in v1: drop and report the peer offline.
      notify(from, to, false);
      return;
    }
    // from-stamping: overwrite with the authenticated sender (no spoofing).
    const forwarded: RelayFrame = { type: 'relay.frame', to, from, sealed: frame.sealed };
    send(target, forwarded);
    if (senderIsNew) {
      notify(from, to, true);
    }
  }

  function handleWatch(conn: Conn, targetId: string): void {
    addWatch(conn.deviceId as string, targetId);
    notify(conn.deviceId as string, targetId, devices.has(targetId));
  }

  function handleMessage(conn: Conn, data: RawData): void {
    const text = typeof data === 'string' ? data : data.toString('utf8');
    const wireBytes = Buffer.byteLength(text, 'utf8');
    let frame: AnyRelayFrame;
    try {
      frame = parseRelayFrame(text);
    } catch (error) {
      logger.debug('dropping unparseable frame', {
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    }

    if (conn.deviceId === null) {
      if (frame.type === 'relay.auth') {
        handleAuth(conn, frame);
      } else {
        sendError(conn, 'not_authed', 'authenticate before sending frames');
      }
      return;
    }

    switch (frame.type) {
      case 'relay.frame':
        handleFrame(conn, frame, wireBytes);
        break;
      case 'relay.watch':
        handleWatch(conn, frame.deviceId);
        break;
      // relay.auth after auth, or relay->device-only frames sent by a device:
      // ignore. They carry no authority here.
      default:
        break;
    }
  }

  function handleClose(conn: Conn): void {
    const deviceId = conn.deviceId;
    if (deviceId === null) {
      return;
    }
    // Only tear down state if this is still the live connection for the device
    // (a replacement may already own the slot).
    if (devices.get(deviceId) !== conn) {
      return;
    }
    devices.delete(deviceId);
    logger.info('device offline', { deviceId, online: devices.size });
    const set = watchers.get(deviceId);
    if (set) {
      for (const watcherId of set) {
        notify(watcherId, deviceId, false);
      }
    }
  }

  function onConnection(ws: WebSocket): void {
    const conn: Conn = {
      ws,
      nonce: randomBytes(32).toString('base64url'),
      deviceId: null,
      limiter: null,
    };
    ws.on('message', (data) => handleMessage(conn, data));
    ws.on('close', () => handleClose(conn));
    ws.on('error', (error) =>
      logger.debug('socket error', { error: error.message }),
    );
    const challenge: RelayChallenge = {
      type: 'relay.challenge',
      nonce: conn.nonce,
      ts: Date.now(),
    };
    send(conn, challenge);
  }

  const httpServer = createServer((req, res) => {
    const path = (req.url ?? '').split('?')[0];
    if (req.method === 'GET' && path === '/healthz') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end('ok');
      return;
    }
    // The push gateway (if configured) owns /register and /wake; everything else
    // falls through to 404.
    if (gateway) {
      gateway.handleRequest(req, res).then(
        (handled) => {
          if (!handled) {
            res.writeHead(404, { 'content-type': 'text/plain' });
            res.end('not found');
          }
        },
        (error: unknown) => {
          logger.error('push gateway error', {
            error: error instanceof Error ? error.message : String(error),
          });
          if (!res.headersSent) {
            res.writeHead(500, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ error: 'internal_error' }));
          }
        },
      );
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  });

  const wss = new WebSocketServer({ server: httpServer });
  wss.on('connection', onConnection);

  return {
    httpServer,
    wss,
    listen(): Promise<number> {
      return new Promise((resolve, reject) => {
        httpServer.once('error', reject);
        httpServer.listen(config.port, () => {
          httpServer.removeListener('error', reject);
          const address = httpServer.address();
          const port =
            address && typeof address === 'object' ? address.port : config.port;
          logger.info('relay listening', { port });
          resolve(port);
        });
      });
    },
    close(): Promise<void> {
      return new Promise((resolve) => {
        for (const client of wss.clients) {
          client.terminate();
        }
        wss.close(() => {
          httpServer.close(() => resolve());
        });
      });
    },
    onlineCount(): number {
      return devices.size;
    },
  };
}
