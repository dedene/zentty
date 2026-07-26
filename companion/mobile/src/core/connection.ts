/**
 * Connection manager: turn a stored {@link PairedMac} into a live
 * {@link TransportLike}, preferring the direct-LAN WebSocket and falling back to
 * the relay, with a transparent switch surface, exponential backoff, and
 * connecting / connected / offline state events.
 *
 * The relay leg speaks the plaintext relay-transport protocol
 * (`relay.challenge` -> signed `relay.auth` -> `relay.ready`, then `relay.frame`
 * routing) — the phone mirror of the Mac's `CompanionRelayTransport`. The
 * end-to-end sealed session bytes ride opaque inside `relay.frame.sealed`, so the
 * relay never sees an envelope.
 */

import { parseRelayFrame } from '@zentty/wire';

import { decodeBase64Url, encodeBase64Url, isValidUnpaddedBase64Url } from './base64url';
import { utf8Bytes } from './crypto';
import type { TransportLike } from './session';
import type { SodiumLike } from './sodium';
import type { PairedMac, PhoneDeviceIdentity } from './storage';

/** Domain-separated prefix signed alongside the relay challenge nonce. Mirrors
 * `CompanionRelayAuthProof.label` and the relay's `RELAY_AUTH_PREFIX`. */
export const RELAY_AUTH_PREFIX = 'zentty-relay-auth:';

// MARK: - Socket seam

/** A text-framed full-duplex link (WebSocket). `receive()` resolves `null` on close. */
export interface TextSocket {
  send(text: string): Promise<void>;
  receive(): Promise<string | null>;
  close(): void;
}

export class RelayAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RelayAuthError';
  }
}

/**
 * Authenticate to the relay over `socket` and return a {@link TransportLike}
 * scoped to `macDeviceId`: outbound bytes are wrapped as `relay.frame`, inbound
 * `relay.frame`s from the Mac are unwrapped to bytes, and peer-status frames are
 * surfaced via `onPeerStatus`.
 */
export async function openRelayTransport(params: {
  socket: TextSocket;
  identity: PhoneDeviceIdentity;
  sodium: SodiumLike;
  macDeviceId: string;
  onPeerStatus?: (online: boolean) => void;
}): Promise<TransportLike> {
  const { socket, identity, sodium, macDeviceId, onPeerStatus } = params;

  const challengeText = await socket.receive();
  if (challengeText === null) {
    throw new RelayAuthError('relay closed before challenge');
  }
  const challenge = parseRelayFrame(challengeText);
  if (challenge.type !== 'relay.challenge') {
    throw new RelayAuthError(`expected relay.challenge, got ${challenge.type}`);
  }
  if (!isValidUnpaddedBase64Url(challenge.nonce)) {
    throw new RelayAuthError('malformed challenge nonce');
  }

  // Sign the UTF-8 bytes of the prefix + the nonce string exactly as transmitted.
  const keypair = sodium.signSeedKeypair(identity.seed);
  const signature = sodium.signDetached(
    utf8Bytes(RELAY_AUTH_PREFIX + challenge.nonce),
    keypair.secretKey,
  );
  await socket.send(
    JSON.stringify({
      type: 'relay.auth',
      deviceId: identity.deviceId,
      pubKey: identity.deviceId,
      sig: encodeBase64Url(signature),
    }),
  );

  const replyText = await socket.receive();
  if (replyText === null) {
    throw new RelayAuthError('relay closed before auth reply');
  }
  const reply = parseRelayFrame(replyText);
  if (reply.type === 'relay.denied') {
    throw new RelayAuthError(`relay denied: ${reply.reason}`);
  }
  if (reply.type !== 'relay.ready') {
    throw new RelayAuthError(`expected relay.ready, got ${reply.type}`);
  }

  return {
    async send(frame: Uint8Array): Promise<void> {
      await socket.send(
        JSON.stringify({
          type: 'relay.frame',
          to: macDeviceId,
          from: identity.deviceId,
          sealed: encodeBase64Url(frame),
        }),
      );
    },
    async receive(): Promise<Uint8Array | null> {
      for (;;) {
        const text = await socket.receive();
        if (text === null) {
          return null;
        }
        let parsed;
        try {
          parsed = parseRelayFrame(text);
        } catch {
          continue; // ignore unparseable relay frames
        }
        if (parsed.type === 'relay.frame') {
          if (parsed.from === macDeviceId) {
            return decodeBase64Url(parsed.sealed);
          }
          continue; // a frame from some other peer — not ours
        }
        if (parsed.type === 'relay.peerStatus') {
          if (parsed.deviceId === macDeviceId) {
            onPeerStatus?.(parsed.online);
          }
          continue;
        }
        // relay.error / stray control frames: ignore and keep reading.
      }
    },
    close(): void {
      socket.close();
    },
  };
}

// MARK: - Backoff

export interface BackoffOptions {
  base?: number;
  cap?: number;
  /** Maps a ceiling to the actual delay. Default: equal jitter. */
  jitter?: (ceiling: number) => number;
}

/** Full-cycle exponential backoff with jitter — the phone twin of `CompanionRelayBackoff`. */
export class Backoff {
  private readonly base: number;
  private readonly cap: number;
  private readonly jitter: (ceiling: number) => number;
  private attempt = 0;

  constructor(options: BackoffOptions = {}) {
    this.base = options.base ?? 1000;
    this.cap = options.cap ?? 60000;
    this.jitter = options.jitter ?? Backoff.equalJitter;
  }

  next(): number {
    const ceiling = Math.min(this.cap, this.base * 2 ** this.attempt);
    this.attempt += 1;
    return this.jitter(ceiling);
  }

  ceiling(attempt: number): number {
    return Math.min(this.cap, this.base * 2 ** attempt);
  }

  reset(): void {
    this.attempt = 0;
  }

  static equalJitter(ceiling: number): number {
    const half = ceiling / 2;
    return half + Math.random() * half;
  }
}

// MARK: - Connection manager

export type TransportKind = 'direct' | 'relay';

export type ConnectionStatus =
  | { state: 'connecting' }
  | { state: 'connected'; transport: TransportKind }
  | { state: 'offline' };

export interface ActiveTransport {
  transport: TransportLike;
  kind: TransportKind;
}

export interface ConnectionManagerOptions {
  mac: PairedMac;
  /** Opens a direct-LAN transport to the Mac's `lanHint`. Rejects on failure. */
  openDirect?: (lanHint: { host: string; port: number }) => Promise<TransportLike>;
  /** Opens an authenticated relay transport to `relayUrl`. Rejects on failure. */
  openRelay?: (relayUrl: string) => Promise<TransportLike>;
  /** Direct-attempt timeout before falling back to relay. Default 3000ms. */
  directTimeoutMs?: number;
  onStatus?: (status: ConnectionStatus) => void;
  backoff?: BackoffOptions;
  /** Sleep helper; injected in tests. */
  delay?: (ms: number) => Promise<void>;
}

export class ConnectionFailedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConnectionFailedError';
  }
}

export class ConnectionManager {
  private readonly opts: ConnectionManagerOptions;
  private readonly backoff: Backoff;
  private readonly delay: (ms: number) => Promise<void>;
  private stopped = false;

  constructor(options: ConnectionManagerOptions) {
    this.opts = options;
    this.backoff = new Backoff(options.backoff);
    this.delay = options.delay ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  /**
   * A single connect attempt: direct first (if a LAN hint + opener exist), then
   * relay. Emits `connecting`, then `connected(kind)` on success. Throws
   * {@link ConnectionFailedError} if neither path succeeds.
   */
  async connectOnce(): Promise<ActiveTransport> {
    this.emit({ state: 'connecting' });
    const { mac, openDirect, openRelay } = this.opts;
    const timeoutMs = this.opts.directTimeoutMs ?? 3000;

    if (mac.lanHint && openDirect) {
      try {
        const transport = await this.withTimeout(openDirect(mac.lanHint), timeoutMs);
        this.emit({ state: 'connected', transport: 'direct' });
        return { transport, kind: 'direct' };
      } catch {
        // fall through to relay
      }
    }

    if (mac.relayUrl && openRelay) {
      try {
        const transport = await openRelay(mac.relayUrl);
        this.emit({ state: 'connected', transport: 'relay' });
        return { transport, kind: 'relay' };
      } catch {
        // fall through to failure
      }
    }

    throw new ConnectionFailedError('no reachable transport (direct and relay both failed)');
  }

  /**
   * Retry {@link connectOnce} with exponential backoff, emitting `offline` between
   * failed attempts, until a transport is obtained or {@link stop} is called.
   */
  async connectWithRetry(): Promise<ActiveTransport> {
    this.stopped = false;
    this.backoff.reset();
    for (;;) {
      if (this.stopped) {
        throw new ConnectionFailedError('connection manager stopped');
      }
      try {
        const active = await this.connectOnce();
        this.backoff.reset();
        return active;
      } catch {
        this.emit({ state: 'offline' });
      }
      if (this.stopped) {
        throw new ConnectionFailedError('connection manager stopped');
      }
      await this.delay(this.backoff.next());
    }
  }

  stop(): void {
    this.stopped = true;
  }

  private emit(status: ConnectionStatus): void {
    this.opts.onStatus?.(status);
  }

  private async withTimeout<T extends TransportLike>(promise: Promise<T>, ms: number): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new ConnectionFailedError('direct connect timed out')), ms);
    });
    try {
      return await Promise.race([promise, timeout]);
    } catch (error) {
      // If the direct transport resolves after we gave up, close it so it does
      // not leak an open socket.
      void promise.then((t) => t.close()).catch(() => undefined);
      throw error;
    } finally {
      if (timer) {
        clearTimeout(timer);
      }
    }
  }
}
